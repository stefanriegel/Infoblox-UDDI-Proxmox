package PVE::Network::SDN::Dns::InfobloxPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use Net::IP;

use base('PVE::Network::SDN::Dns::Plugin');

sub type {
    return 'infobloxuddi';
}

sub properties {
    return {
        token => {
            type => 'string',
            description => 'Infoblox API token',
        },
        dns_view => {
            type => 'string',
            description => 'Infoblox DNS View name (default: "default")',
        },
    };
}

sub options {
    return {
        url      => { optional => 0 },
        token    => { optional => 0 },
        dns_view => { optional => 1 },
        ttl      => { optional => 1 },
    };
}

# --- Private helper functions ---

sub infoblox_api_request {
    my ($config, $method, $path, $params) = @_;

    my $url = $config->{url};
    $url = "https://$url" if $url !~ m|^https?://|;

    return PVE::Network::SDN::api_request(
        $method,
        "${url}/api/ddi/v1${path}",
        [
            'Content-Type',  'application/json; charset=UTF-8',
            'Authorization', "Token $config->{token}",
        ],
        $params,
    );
}

sub get_dns_view_id {
    my ($config) = @_;

    my $view_name = $config->{dns_view} || 'default';

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/view?_filter=name==\"$view_name\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub get_auth_zone_id {
    my ($config, $zone_fqdn, $view_id) = @_;

    # Append trailing dot if missing
    $zone_fqdn .= '.' unless $zone_fqdn =~ /\.$/;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/auth_zone?_filter=fqdn==\"$zone_fqdn\" and view==\"$view_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub find_dns_record_id {
    my ($config, $fqdn, $type, $view_id) = @_;

    # Append trailing dot if missing
    $fqdn .= '.' unless $fqdn =~ /\.$/;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/record?_filter="
              . "absolute_name_spec==\"$fqdn\""
              . " and type==\"$type\""
              . " and view==\"$view_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

# --- DNS record lifecycle methods ---

sub add_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';
    my $fqdn = "${hostname}.${zone}";

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    # Resolve auth zone ID
    my $zone_id = get_auth_zone_id($plugin_config, $zone, $view_id);
    if (!$zone_id) {
        die "zone $zone not found in Infoblox\n" if !$noerr;
        return;
    }

    eval {
        # Check for existing A record (GET-before-POST idempotency)
        my $existing_id = find_dns_record_id($plugin_config, $fqdn, 'A', $view_id);

        my $ttl = $plugin_config->{ttl} || 3600;
        my $params = {
            type    => 'A',
            rdata   => { address => $ip },
            ttl     => $ttl,
            comment => 'managed by proxmox',
            tags    => { source => 'proxmox' },
        };

        if ($existing_id) {
            # Record exists -- update via PATCH
            infoblox_api_request($plugin_config, "PATCH",
                "/$existing_id", $params);
        } else {
            # Create new record via POST
            $params->{name_in_zone} = $hostname;
            $params->{zone}         = $zone_id;
            $params->{view}         = $view_id;
            infoblox_api_request($plugin_config, "POST",
                "/dns/record", $params);
        }
    };

    if ($@) {
        die "error adding A record $fqdn: $@\n" if !$noerr;
        return;
    }

    return;
}

sub add_ptr_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    # Resolve auth zone ID for the reverse zone
    my $zone_id = get_auth_zone_id($plugin_config, $zone, $view_id);
    if (!$zone_id) {
        die "zone $zone not found in Infoblox\n" if !$noerr;
        return;
    }

    eval {
        # Compute PTR rdata.dname: hostname is already FQDN from Proxmox, just add trailing dot
        my $dname = $hostname;
        $dname .= '.' unless $dname =~ /\.$/;

        # Compute full reverse IP name (e.g., "5.0.0.10.in-addr.arpa.")
        my $reverse_ip = Net::IP->new($ip)->reverse_ip();

        # Compute name_in_zone: strip the zone suffix from the full reverse name
        my $zone_suffix = $zone;
        $zone_suffix .= '.' unless $zone_suffix =~ /\.$/;
        my $name_in_zone = $reverse_ip;
        $name_in_zone =~ s/\.\Q$zone_suffix\E$//;

        # Check for existing PTR record (GET-before-POST idempotency)
        my $existing_id = find_dns_record_id($plugin_config, $reverse_ip, 'PTR', $view_id);

        my $ttl = $plugin_config->{ttl} || 3600;
        my $params = {
            type    => 'PTR',
            rdata   => { dname => $dname },
            ttl     => $ttl,
            comment => 'managed by proxmox',
            tags    => { source => 'proxmox' },
        };

        if ($existing_id) {
            # Record exists -- update via PATCH
            infoblox_api_request($plugin_config, "PATCH",
                "/$existing_id", $params);
        } else {
            # Create new record via POST
            $params->{name_in_zone} = $name_in_zone;
            $params->{zone}         = $zone_id;
            $params->{view}         = $view_id;
            infoblox_api_request($plugin_config, "POST",
                "/dns/record", $params);
        }
    };

    if ($@) {
        die "error adding PTR record for $ip: $@\n" if !$noerr;
        return;
    }

    return;
}

sub del_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';
    my $fqdn = "${hostname}.${zone}";

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    eval {
        # Find existing A record
        my $record_id = find_dns_record_id($plugin_config, $fqdn, 'A', $view_id);

        if ($record_id) {
            # Record found -- delete it
            infoblox_api_request($plugin_config, "DELETE",
                "/$record_id", undef);
        }
        # If not found, return silently (idempotent delete)
    };

    if ($@) {
        die "error deleting A record $fqdn: $@\n" if !$noerr;
        return;
    }

    return;
}

sub del_ptr_record {
    my ($class, $plugin_config, $zone, $ip, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    eval {
        # Compute full reverse IP name
        my $reverse_ip = Net::IP->new($ip)->reverse_ip();

        # Find existing PTR record by reverse IP name
        my $record_id = find_dns_record_id($plugin_config, $reverse_ip, 'PTR', $view_id);

        if ($record_id) {
            # Record found -- delete it
            infoblox_api_request($plugin_config, "DELETE",
                "/$record_id", undef);
        }
        # If not found, return silently (idempotent delete)
    };

    if ($@) {
        die "error deleting PTR record for $ip: $@\n" if !$noerr;
        return;
    }

    return;
}

sub verify_zone {
    my ($class, $plugin_config, $zone, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    # Resolve auth zone
    my $zone_id = get_auth_zone_id($plugin_config, $zone, $view_id);
    if (!$zone_id) {
        die "zone $zone not found in Infoblox\n" if !$noerr;
        return;
    }

    return;
}

sub get_reversedns_zone {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;

    # Resolve DNS View ID; return "" if not found (Proxmox skips PTR when empty)
    my $view_id = get_dns_view_id($plugin_config);
    return "" if !$view_id;

    # Compute full reverse IP name (e.g., "5.0.0.10.in-addr.arpa.")
    my $reverse_ip = Net::IP->new($ip)->reverse_ip();

    # Split on '.' and remove host part (least significant octet)
    my @parts = split(/\./, $reverse_ip);
    shift @parts;  # remove host part

    # Walk up the reverse name hierarchy to find matching auth_zone
    # Minimum meaningful reverse zone is x.in-addr.arpa. (3 parts without trailing dot)
    while (scalar(@parts) > 2) {
        my $candidate = join('.', @parts) . '.';  # trailing dot for DNS convention
        my $zone_id = get_auth_zone_id($plugin_config, $candidate, $view_id);
        if ($zone_id) {
            return $candidate;
        }
        shift @parts;  # try parent zone
    }

    return "";  # no reverse zone found
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Single GET to /dns/view tests reachability + auth + DNS View existence (3-in-1)
    my $result = eval {
        infoblox_api_request(
            $plugin_config, "GET",
            "/dns/view?_filter=name==\"$view_name\"",
            undef,
        );
    };

    if ($@) {
        # Distinguish between connectivity and auth errors
        if ($@ =~ /401|Unauthorized|403|Forbidden/i) {
            die "Authentication failed: invalid API token\n";
        }
        die "Cannot reach Infoblox API at $plugin_config->{url}: $@\n";
    }

    # DNS View existence
    if (!$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        die "DNS View \"$view_name\" not found in Infoblox\n";
    }

    return;
}

1;
