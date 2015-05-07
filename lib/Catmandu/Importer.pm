package Catmandu::Importer;

use namespace::clean;
use Catmandu::Sane;
use Catmandu::Util qw(io is_value is_hash_ref);
use Coro;
use LWP::Protocol::AnyEvent::http;
use LWP::UserAgent;
use HTTP::Request ();
use URI ();
use URI::Template ();
use Moo::Role;

with 'Catmandu::Logger';
with 'Catmandu::Iterable';
with 'Catmandu::Fixable';
with 'Catmandu::Serializer';

around generator => sub {
    my ($orig, $self) = @_;
    my $generator = $orig->($self);
    if (my $fixer = $self->_fixer) {
        return $fixer->fix($generator);
    }
    $generator;
};

has file => (is => 'lazy');
has fh => (is => 'lazy');
has encoding => (is => 'lazy');
has method => (is => 'lazy');
has headers => (is => 'lazy');
has agent => (is => 'ro', predicate => 1);
has max_redirect => (is => 'ro', predicate => 1);
has timeout => (is => 'ro', predicate => 1);
has verify_hostname => (is => 'ro', default => sub { 1 });
has body => (is => 'ro', predicate => 1);
has variables => (is => 'ro', predicate => 1);
has paginate => (is => 'ro');
has total_param => (is => 'ro', default => sub { 'total' });
has limit_param => (is => 'ro', default => sub { 'limit' });
has start_param => (is => 'ro', default => sub { 'start' });
has url => (is => 'lazy', init_arg => undef);
has _url_template => (is => 'ro', predicate => 'has_url', init_arg => 'url');
has _http_client => (is => 'ro', lazy => 1, builder => '_build_http_client', init_arg => undef);
has _channel => (is => 'ro', lazy => 1, builder => '_build_channel', init_arg => undef);

sub _build_file {
    \*STDIN;
}

sub _build_headers {
    [];
}

sub _build_method {
    'GET';
}

sub _build_channel {
    Coro::Channel->new(1);
}

sub _build_url {
    my ($self) = @_;
    return unless $self->has_url;
    my $url = $self->_url_template;
    if ($self->has_variables) {
        my $url_template = URI::Template->new($url);
        my $vars = $self->variables;
        $url_template->process(is_hash_ref($vars) ? %$vars : $vars);
    } else {
        URI->new($url);
    }
}

sub _build_fh {
    my ($self) = @_;
    my $io;

    if ($self->has_url) {
        my $channel = $self->_channel;

        my $url = $self->url;

        async {
            while (defined($url)) {
                $url = $self->_do_http_request($url);
            }
        };

        $io = sub {
            my $data = $channel->get;
            $data->throw if ref $data; # got a http error
            $data;
        };
    } else {
        $io = $self->file;
    }
    
    io($io, mode => 'r', binmode => $self->encoding);
}

sub _build_encoding {
    ':utf8';
}

sub _build_http_client {
    my ($self) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->agent($self->agent) if $self->has_agent;
    $ua->max_redirect($self->max_redirect) if $self->has_max_redirect;
    $ua->timeout($self->timeout) if $self->has_timeout;
    $ua->ssl_opts(verify_hostname => $self->verify_hostname);
    $ua->protocols_allowed([qw(http https)]);
    $ua;
}

sub _do_http_request {
    my ($self, $url) = @_;
    #$url //= $self->url;
say STDERR $url;
    my $channel = $self->_channel;
    my $request = HTTP::Request->new($self->method, $url, $self->headers);

    if ($self->has_body) {
        my $body = $self->body;
        if (ref $body) {
            $body = $self->serialize($body);
        } elsif ($self->has_variables) {
            my $vars = $self->variables;
            if (is_hash_ref($vars)) { # named variables
                for my $key (keys %$vars) {
                    my $var = $vars->{$key};
                    $body =~ s/{$key}/$var/; 
                }
            } else { # positional variables
                for my $var (@$vars) {
                    $body =~ s/{\w+}/$var/; 
                }
            }
        }

        $request->content($body);
    }

    local $SIG{PIPE} = sub { exit };

    if ($self->paginate) {
        my $response = $self->_http_client->request($request);

        unless ($response->is_success) {
            $self->_http_error($url, $response);
            return;
        }
        my $data = $response->decoded_content;
        # TODO we're deserializing twice here
        # TODO yield ?
        $channel->put($data);
        $data = $self->deserialize($data);
        if (is_hash_ref($data)) {
            # TODO push all errors to channel
            my $total = $data->{$self->total_param} // Catmandu::Error->throw('total missing');
            my $start = $data->{$self->start_param} // 0;
            my $limit = $data->{$self->limit_param} // Catmandu::Error->throw('limit missing');
            if ($start * $limit < $total) {
                $url->query_form(
                    $self->start_param => $start + $limit - 1,                
                    $self->limit_param => $limit,                
                );
                return $url;
            }
        }
    } else {
        my $response = $self->_http_client->request($request, sub {
            my ($data, $res) = @_;
            $res->content($data);
            $channel->put($res->decoded_content); 
        });

        unless ($response->is_success) {
            $self->_http_error($url, $response);
        }
    }

    return;
}

sub _http_error {
    my ($self, $url, $response) = @_;
    my $response_headers = [];
    for my $header ($response->header_field_names) {
        push @$response_headers, $header, $response->header($header);
    }
    # push error through the channel
    $self->_channel->put(Catmandu::HTTPError->new({
        code             => $response->code,
        message          => $response->status_line,
        url              => $url,
        method           => $self->method,
        request_headers  => $self->headers,
        request_body     => $self->body,
        response_headers => $response_headers,
        response_body    => $response->decoded_content,
    }));
}

sub readline {
    $_[0]->fh->getline;
}

sub readall {
    join('', $_[0]->fh->getlines);
}

=head1 NAME

Catmandu::Importer - Namespace for packages that can import

=head1 SYNOPSIS

    package Catmandu::Importer::Hello;

    use Catmandu::Sane;
    use Moo;

    with 'Catmandu::Importer';

    sub generator {
        my ($self) = @_;
        state $fh = $self->fh;
        my $n = 0;
        return sub {
            $self->log->debug("generating record " . ++$n);
            my $name = $self->readline;
            return defined $name ? { "hello" => $name } : undef;
        };
    } 

    package main;

    use Catmandu;

    my $importer = Catmandu->importer('Hello', file => '/tmp/names.txt');
    $importer->each(sub {
        my $items = shift;
        ...
    });

    # Or on the command line
    $ catmandu convert Hello to YAML < /tmp/names.txt


=head1 DESCRIPTION

A Catmandu::Importer is a Perl package that can import data from an external
source (a file, the network, ...). Most importers read from an input stream, 
such as STDIN, a given file, or an URL to fetch data from, so this base class
provides helper method for consuming the input stream once.

Every Catmandu::Importer is a L<Catmandu::Fixable> and thus inherits a 'fix'
parameter that can be set in the constructor. When given then each item returned
by the generator will be automatically Fixed using one or more L<Catmandu::Fix>es.
E.g.
    
    my $importer = Catmandu->importer('Hello',fix => ['upcase(hello)']);
    $importer->each( sub {
        my $item = shift ; # Every item will be upcased... 
    } );

Every Catmandu::Importer is a L<Catmandu::Iterable> and inherits the methods (C<first>,
C<each>, C<to_array>...) etc.

=head1 CONFIGURATION

=over

=item file

Read input from a local file given by its path. Alternatively a scalar
reference can be passed to read from a string.

=item fh

Read input from an L<IO::Handle>. If not specified, L<Catmandu::Util::io> is used to
create the input stream from the C<file> argument or by using STDIN.

=item encoding

Binmode of the input stream C<fh>. Set to C<:utf8> by default.

=item fix

An ARRAY of one or more fixes or file scripts to be applied to imported items.

=back

=head1 METHODS

=head2 readline

Read a line from the input stream. Equivalent to C<< $importer->fh->getline >>.

=head2 readall

Read the whole input stream as string.

=head2 first, each, rest , ...

See L<Catmandu::Iterable> for all inherited methods.

=head1 SEE ALSO

L<Catmandu::Iterable> , L<Catmandu::Fix> ,
L<Catmandu::Importer::CSV>, L<Catmandu::Importer::JSON> , L<Catmandu::Importer::YAML>

=cut

1;
