package Catmandu::Importer;

use namespace::clean;
use Catmandu::Sane;
use Catmandu::Util qw(io is_value is_hash_ref);
use Furl::HTTP;
use URI::Template;
use Moo::Role;

with 'Catmandu::Logger';
with 'Catmandu::Iterable';
with 'Catmandu::Fixable';

around generator => sub {
    my ($orig, $self) = @_;
    my $generator = $orig->($self);
    if (my $fixer = $self->_fixer) {
        return $fixer->fix($generator);
    }
    $generator;
};

has file => (
    is => 'lazy',
);

has url => (
    is        => 'ro',
    predicate => 1,
);

has method => (
    is => 'lazy',
);

has headers => (
    is => 'lazy',
);

has body => (
    is        => 'ro',
    predicate => 1,
);

has variables => (
    is        => 'ro',
    predicate => 1,
    coerce    => sub {
        my $vars = $_[0];
        $vars = [$vars] if is_value $vars;
        $vars;   
    },
);

has fh => (
    is => 'lazy',
);

has encoding => (
    is => 'lazy',
);

has http_client => (
    is => 'lazy',
); 

sub _build_file {
    \*STDIN;
}

sub _build_headers {
    [];
}

sub _build_method {
    'GET';
}

sub _build_fh {
    my ($self) = @_;
    my $io;
    # TODO paging
    if ($self->has_url) {
        my $url = $self->url;
        if ($self->has_variables) {
            my $url_template = URI::Template->new($url);
            my $vars = $self->variables;
            $url = $url_template->process(is_hash_ref($vars) ? %$vars : $vars);
        }
        my %args = (
            method  => $self->method, 
            url     => $self->url,
            headers => $self->headers,
        );
        $args{content} = $self->body if $self->has_body;
        my ($http_version, $code, $message, $headers, $body) = $self->http_client->request(%args);
        if ($code < 200 || $code >= 300) {
            Catmandu::HTTPError->throw({
                code => $code,
                message => $message,
                url => $url,
                method => $self->method,
                request_headers => $self->headers,
                request_body => $self->body,
                response_headers => $headers,
                response_body => $body,
            });
        }
        $io = \$body;
    } else {
        $io = $self->file;
    }
    io($io, mode => 'r', binmode => $self->encoding);
}

sub _build_encoding {
    ':utf8';
}

sub _build_http_client {
    # TODO client options
    Furl::HTTP->new;
}

sub readline {
    $_[0]->fh->getline;
}

sub readall {
    join '', $_[0]->fh->getlines;
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
