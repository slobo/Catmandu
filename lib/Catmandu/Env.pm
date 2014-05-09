package Catmandu::Env;

use namespace::clean;
use Catmandu::Sane;
use Catmandu::Util qw(require_package use_lib read_yaml read_json :is :check);
use Catmandu::Fix;
use Clone qw(clone);
use Config::Onion;
use File::Spec;
use Moo;

with 'MooX::Log::Any';

has load_paths => (
    is      => 'ro',
    default => sub { [] },
    coerce  => sub {
        [ map { File::Spec->canonpath($_) }split /,/, join ',', ref $_[0] ? @{$_[0]} : $_[0] ];
    },
);

has config_extensions => (is => 'ro', builder => 'default_config_extensions');
has config => (is => 'rwp', default => sub { +{} });

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

sub default_config_extensions {
    [qw(yaml yml json pl)];
}

sub BUILD {
    my ($self) = @_;

    my @config_dirs = @{$self->load_paths};
    my @lib_dirs;

    for my $dir (@config_dirs) {
        if (! -d $dir) {
            Catmandu::Error->throw("load path $dir doesn't exist");
        }

        my $lib_dir = File::Spec->catdir($dir, 'lib');

        if (-d -r $lib_dir) {
            push @lib_dirs, $lib_dir;
        }
    }

    if (@config_dirs) {
        my $exts = $self->default_config_extensions;
        my @globs = map { my $dir = $_;
                          map { File::Spec->catfile($dir, "catmandu*.$_") } @$exts }
                              reverse @config_dirs;

        local $Config::Onion::prefix_key = '_path';
        my $config = Config::Onion->new;
        $config->load_glob(@globs);
        $self->_set_config($config->get);
    }

    if (@lib_dirs) {
        lib->import(@lib_dirs);
    }
}

sub load_path {
    $_[0]->load_paths->[0];
}

sub roots {
    goto &load_paths;
}

sub root {
    goto &load_path;
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
