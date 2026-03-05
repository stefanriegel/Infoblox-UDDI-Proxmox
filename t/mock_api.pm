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

# Override PVE::Network::SDN::api_request with our mock
{
    no warnings 'redefine';
    *PVE::Network::SDN::api_request = sub {
        my ($method, $url, $headers, $params) = @_;

        push @call_history, {
            method  => $method,
            url     => $url,
            headers => $headers,
            params  => $params,
        };

        # Try to match against registered mocks
        for my $key (keys %mock_errors) {
            my ($mock_method, $pattern) = split(/:/, $key, 2);
            if ($method eq $mock_method && $url =~ /\Q$pattern\E/) {
                die $mock_errors{$key};
            }
        }

        for my $key (keys %mock_responses) {
            my ($mock_method, $pattern) = split(/:/, $key, 2);
            if ($method eq $mock_method && $url =~ /\Q$pattern\E/) {
                return $mock_responses{$key};
            }
        }

        die "unexpected api_request: $method $url";
    };
}

1;
