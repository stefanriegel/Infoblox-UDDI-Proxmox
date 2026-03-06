package mock_api;

use strict;
use warnings;

# Storage for mock responses and call history
my %mock_responses;   # keyed by "$method:$path_pattern"
my %mock_errors;      # keyed by "$method:$path_pattern"
my @call_history;     # arrayref of {method, url, headers, params}

sub mock_response {
    my ($method, $path_pattern, $response_data) = @_;
    $mock_responses{"$method:$path_pattern"} = $response_data;
}

sub mock_error {
    my ($method, $path_pattern, $error_message) = @_;
    $mock_errors{"$method:$path_pattern"} = $error_message;
}

sub clear_mocks {
    %mock_responses = ();
    %mock_errors = ();
    @call_history = ();
}

sub get_last_call {
    return $call_history[-1];
}

sub get_all_calls {
    return \@call_history;
}

# URL-decode a string (e.g., %3D -> =, %22 -> ", %20 -> space)
sub _uri_decode {
    my ($str) = @_;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# Helper: find the longest matching pattern for a given method+url
sub _best_match {
    my ($registry, $method, $url) = @_;
    # URL-decode the incoming URL so mock patterns can use plain text
    my $decoded_url = _uri_decode($url);
    my $best_key;
    my $best_len = -1;
    for my $key (keys %$registry) {
        my ($mock_method, $pattern) = split(/:/, $key, 2);
        if ($method eq $mock_method && $decoded_url =~ /\Q$pattern\E/) {
            if (length($pattern) > $best_len) {
                $best_key = $key;
                $best_len = length($pattern);
            }
        }
    }
    return $best_key;
}

# Override PVE::Network::SDN::api_request with our mock
{
    no warnings 'redefine';
    *PVE::Network::SDN::api_request = sub {
        my ($method, $url, $headers, $params) = @_;

        # Store URL-decoded version so test assertions match plain text patterns
        push @call_history, {
            method  => $method,
            url     => _uri_decode($url),
            headers => $headers,
            params  => $params,
        };

        # Check errors first (longest match wins)
        my $err_key = _best_match(\%mock_errors, $method, $url);
        die $mock_errors{$err_key} if defined $err_key;

        # Check responses (longest match wins)
        my $resp_key = _best_match(\%mock_responses, $method, $url);
        return $mock_responses{$resp_key} if defined $resp_key;

        die "unexpected api_request: $method $url";
    };
}

1;
