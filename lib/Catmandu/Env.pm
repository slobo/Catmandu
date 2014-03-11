package Catmandu::Env;

use namespace::clean;
use Catmandu::Sane;
use Catmandu::Util qw(require_package use_lib read_yaml read_json :is :check);
use Catmandu::Fix;
use Clone qw(clone);
use File::Spec;
use Moo;

with 'MooX::Log::Any';

has load_paths => (
    is      => 'ro',
    default => sub { [] },
    coerce  => sub {
        [map { File::Spec->rel2abs($_) }
            split /,/, join ',', ref $_[0] ? @{$_[0]} : $_[0]];
    },
);

has roots => (
    is      => 'ro',
    default => sub { [] },
);

has config => (is => 'ro', default => sub { +{} });
has stores => (is => 'ro', default => sub { +{} });
has fixers => (is => 'ro', default => sub { +{} });

has default_store => (is => 'ro', default => sub { 'default' });
has default_fixer => (is => 'ro', default => sub { 'default' });
has default_importer => (is => 'ro', default => sub { 'default' });
has default_exporter => (is => 'ro', default => sub { 'default' });
has default_importer_package => (is => 'ro', default => sub { 'JSON' });
has default_exporter_package => (is => 'ro', default => sub { 'JSON' });
has store_namespace => (is => 'ro', default => sub { 'Catmandu::Store' });
has fixes_namespace => (is => 'ro', default => sub { 'Catmandu::Fix' }); # TODO unused
has importer_namespace => (is => 'ro', default => sub { 'Catmandu::Importer' });
has exporter_namespace => (is => 'ro', default => sub { 'Catmandu::Exporter' });

sub BUILD {
    my ($self) = @_;

    for my $load_path (@{$self->load_paths}) {
        my @dirs = grep length, File::Spec->splitdir($load_path);

        for (; @dirs; pop @dirs) {
            my $path = File::Spec->catdir(File::Spec->rootdir, @dirs);

            opendir my $dh, $path or last;

            my @files = sort
                        grep { -f -r File::Spec->catfile($path, $_) }
                        grep { /^catmandu\./ }
                        readdir $dh;
            for my $file (@files) {
                if (my ($keys, $ext) = $file =~ /^catmandu(.*)\.(pl|yaml|yml|json)$/) {
                    $keys = substr $keys, 1 if $keys; # remove leading dot

                    $file = File::Spec->catfile($path, $file);

                    my $config = $self->config;
                    my $c;

                    $config = $config->{$_} ||= {} for split /\./, $keys;

                    if ($ext eq 'pl')    { $c = do $file }
                    if ($ext =~ /ya?ml/) { $c = read_yaml($file) }
                    if ($ext eq 'json')  { $c = read_json($file) }

                    $config->{$_} = $c->{$_} for keys %$c;
                }
            }

            if (@files) {
                unshift @{$self->roots}, $path;

                my $lib_path = File::Spec->catdir($path, 'lib');
                if (-d -r $lib_path) {
                    use_lib $lib_path;
                }

                last;
            }
        }
    }
}

sub root {
    my ($self) = @_; $self->roots->[0];
}

sub fixer {
    my $self = shift;
    if (ref $_[0]) {
        return Catmandu::Fix->new(fixes => $_[0]);
    }

    my $key = $_[0] || $self->default_fixer;

    my $fixers = $self->fixers;

    $fixers->{$key} || do {
        if (my $fixes = $self->config->{fixer}{$key}) {
            return $fixers->{$key} = Catmandu::Fix->new(fixes => $fixes);
        }
        return Catmandu::Fix->new(fixes => [@_]);
    }
}

sub store {
    my $self = shift;
    my $name = shift;

    my $key = $name // $self->default_store;

    my $stores = $self->stores;

    $stores->{$key} || do {
        if (my $conf = $self->store_config($key)) {
            my $pkg = $self->require_store($conf->{package});
            my $attrs = { %{$conf->{options}}, %{$self->extract_options_for($pkg, @_)} };
            return $stores->{$key} = $pkg->new($attrs);
        }
        unless (defined $name) {
            Catmandu::BadArg->throw("unknown store '$key'");
        }
        my $pkg = $self->require_store($name);
        my $attrs = $self->extract_options_for($pkg, @_);
        $pkg->new($attrs);
    };
}

sub importer {
    my $self = shift;
    my $name = shift;
    if (my $conf = $self->importer_config($name)) {
        my $pkg = $self->require_importer($conf->{package});
        my $attrs = { %{$conf->{options}}, %{$self->extract_options_for($pkg, @_)} };
        return $pkg->new($attrs);
    }
    my $pkg = $self->require_importer($name);
    my $attrs = $self->extract_options_for($pkg, @_);
    $pkg->new($attrs);
}

sub exporter {
    my $self = shift;
    my $name = shift;
    if (my $conf = $self->exporter_config($name)) {
        my $pkg = $self->require_exporter($conf->{package});
        my $attrs = { %{$conf->{options}}, %{$self->extract_options_for($pkg, @_)} };
        return $pkg->new($attrs);
    }
    my $pkg = $self->require_exporter($name);
    my $attrs = $self->extract_options_for($pkg, @_);
    $pkg->new($attrs);
}

sub require_store {
    my ($self, $pkg) = @_;
    require_package($pkg, $self->store_namespace);
}

sub require_exporter {
    my ($self, $pkg) = @_;
    require_package($pkg || $self->default_exporter_package, $self->exporter_namespace);
}

sub require_importer {
    my ($self, $pkg) = @_;
    require_package($pkg || $self->default_importer_package, $self->importer_namespace);
}

sub store_config {
    my ($self, $key) = @_;
    my $config = $self->config;
    $key //= $self->default_store;
    return unless exists $config->{store}{$key};
    check_hash_ref(my $conf = $config->{store}{$key});
    $conf = clone($conf);
    check_string($conf->{package});
    check_hash_ref($conf->{options} //= {});
    $conf;
}

sub exporter_config {
    my ($self, $key) = @_;
    my $config = $self->config;
    $key //= $self->default_exporter;
    return unless exists $config->{exporter}{$key};
    check_hash_ref(my $conf = $config->{exporter}{$key});
    $conf = clone($conf);
    check_string($conf->{package} //= $self->default_exporter_package);
    check_hash_ref($conf->{options} //= {});
    $conf;
}

sub importer_config {
    my ($self, $key) = @_;
    my $config = $self->config;
    $key //= $self->default_importer;
    return unless exists $config->{importer}{$key};
    check_hash_ref(my $conf = $config->{importer}{$key});
    $conf = clone($conf);
    check_string($conf->{package} //= $self->default_importer_package);
    check_hash_ref($conf->{options} //= {});
    $conf;
}

sub extract_options_for {
    my $self = shift;
    my $pkg  = shift;
    my $opts;
    if (@_) {
        my $prim_opt = $pkg->primary_attribute;
        my $prim_val;

        if (ref $_[-1] eq 'HASH') {
            $opts = pop;
        }

        if (@_ % 2 == 1) {
            $prim_val = shift;
        }
        if (@_ && @_ % 2 == 0) {
            $opts = {@_};
        }
        if (defined $prim_opt && defined $prim_val) {
            $opts->{$prim_opt} = $prim_val;
        }
    } else {
        $opts = {};
    }

    $opts;
}

1;
