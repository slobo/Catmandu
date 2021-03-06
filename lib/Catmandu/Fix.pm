package Catmandu::Fix;

use Catmandu::Sane;
use Catmandu;
use Catmandu::Util qw(:is :string :misc);
use Clone qw(clone);

sub _eval_emit {
    use warnings FATAL => 'all';
    eval $_[0];
}

use Moo;
use Catmandu::Fix::Parser;
use Data::Dumper ();
use B ();

with 'Catmandu::Logger';

has tidy         => (is => 'ro');
has parser       => (is => 'lazy');
has fixer        => (is => 'lazy', init_arg => undef);
has _num_labels  => (is => 'rw', lazy => 1, init_arg => undef, default => sub { 0; });
has _num_vars    => (is => 'rw', lazy => 1, init_arg => undef, default => sub { 0; });
has _captures    => (is => 'ro', lazy => 1, init_arg => undef, default => sub { +{}; });
has var          => (is => 'ro', lazy => 1, init_arg => undef, builder => 'generate_var');
has _fixes       => (is => 'ro', init_arg => 'fixes', default => sub { [] });
has fixes        => (is => 'ro', lazy => 1, init_arg => undef, builder => '_build_fixes');
has _reject      => (is => 'ro', init_arg => undef, default => sub { +{}; });
has _reject_var  => (is => 'ro', lazy => 1, init_arg => undef, builder => '_build_reject_var');
has _reject_label => (is => 'ro', lazy => 1, init_arg => undef, builder => 'generate_label');
has _fixes_var   => (is => 'ro', lazy => 1, init_arg => undef, builder => '_build_fixes_var');
has _current_fix_var  => (is => 'ro', lazy => 1, init_arg => undef, builder => '_build_current_fix_var');

sub _build_parser {
    Catmandu::Fix::Parser->new;
}

sub _build_fixes {
    my ($self) = @_;
    my $fixes_arg = $self->_fixes;
    my $fixes = [];

    for my $fix (@$fixes_arg) {
        if (is_code_ref($fix)) {
            push @$fixes, require_package('Catmandu::Fix::code')->new($fix);
        } elsif (ref $fix) {
            push @$fixes, $fix;
        } elsif (is_string($fix) && $fix !~ /[\n()]/ and -X $fix) {
            push @$fixes, require_package('Catmandu::Fix::cmd')->new($fix);
        } elsif (is_string($fix)) {
            push @$fixes, @{$self->parser->parse($fix)};
        }
    }

    $fixes;
}

sub _build_fixer {
    my ($self) = @_;
    local $@;
    _eval_emit($self->emit, $self->_captures) or Catmandu::Error->throw($@);
}

sub _build_reject_var {
    my ($self) = @_;
    $self->capture($self->_reject);
}

sub _is_reject {
    my ($self, $data) = @_;
    ref $data && $data == $self->_reject;
}

sub _build_fixes_var {
    my ($self) = @_;
    $self->capture($self->fixes);
}

sub _build_current_fix_var {
    my ($self) = @_;
    $self->generate_var;
}

sub fix {
    my ($self, $data) = @_;

    my $fixer = $self->fixer;

    if (is_hash_ref($data)) {
        my $d = $fixer->($data);
        return if $self->_is_reject($d);
        return $d;
    }

    if (is_instance($data)) {
        return $data->map(sub { $fixer->($_[0]) })
                    ->reject(sub { $self->_is_reject($_[0]) });
    }

    if (is_code_ref($data)) {
        return sub {
            while (1) {
                my $d = $fixer->($data->() // return);
                next if $self->_is_reject($d);
                return $d;
            }
        };
    }

    if (is_array_ref($data)) {
        return [ grep { !$self->_is_reject($_) } map { $fixer->($_) } @$data ];
    }

    Catmandu::BadArg->throw("must be hashref, arrayref, coderef or iterable object");
}

sub generate_var {
    my ($self) = @_;
    my $n = $self->_num_vars;
    $self->_num_vars($n + 1);
    "\$__$n";
}

sub generate_label {
    my ($self) = @_;
    my $n = $self->_num_labels;
    $self->_num_labels($n + 1);
    my $addr = Scalar::Util::refaddr($self);
    "__FIX__${addr}__${n}";
}

sub capture {
    my ($self, $capture) = @_;
    my $var = $self->generate_var;
    $self->_captures->{$var} = $capture;
    $var;
}

sub emit {
    my ($self) = @_;
    my $var = $self->var;
    my $err = $self->generate_var;
    my $captures = $self->_captures;
    my $reject_var = $self->_reject_var;
    my $current_fix_var = $self->_current_fix_var;
    my $perl = "";

    $perl .= "sub {";
    $perl .= $self->emit_declare_vars($current_fix_var);
    $perl .= $self->emit_declare_vars($var, '$_[0]');
    $perl .= "eval {";

    # Loop over all the fixes and emit their code, binded to Binds if required
    $perl .= $self->emit_fixes($self->fixes);

    $perl .= "return ${var};";
    $perl .= $self->_reject_label . ": return ${reject_var};";
    $perl .= "} or do {";
    $perl .= $self->emit_declare_vars($err, '$@');
    $perl .= "${err}->throw if is_instance(${err},'Throwable::Error');";
    $perl .= "Catmandu::FixError->throw(message => ${err}, data => ${var}, fix => ${current_fix_var});";
    $perl .= "};";
    $perl .= "};";

    if (%$captures) {
        my @captured_vars = map {
            $self->emit_declare_vars($_, '$_[1]->{'.$self->emit_string($_).'}');
        } keys %$captures;
        $perl = join '', @captured_vars, $perl;
    }

    if ($self->tidy || $self->log->is_debug) {
        require Perl::Tidy;

        my $tidy_perl = "";
        my $err = "";
        my $log = "";

        my $has_err = Perl::Tidy::perltidy(
            argv        => "-se",
            source      => \$perl,
            destination => \$tidy_perl,
            logfile     => \$log,
            stderr      => \$err,
        );
        if ($has_err) {
            Catmandu::Error->throw($err);
        }

        $perl = $tidy_perl;
    }

    $self->log->debug($perl);

    $perl;
}

# Emit an array of fixes
sub emit_fixes {
    my ($self,$fixes) = @_;
    my $perl = '';

    for (my $i = 0; $i < @{$fixes}; $i++) {
        my $fix = $fixes->[$i];
        $perl .= $self->_current_fix_var . " = " . $self->_fixes_var . "->[${i}];";
        $perl .= $self->emit_fix($fix);
    }

    $perl;
}

sub emit_reject {
    my ($self) = @_;
    "goto " .  $self->_reject_label . ";";
}

sub emit_fix {
    my ($self, $fix) = @_;
    my $perl;

    if ($fix->can('emit')) {
        $perl = $self->emit_block(sub {
            my ($label) = @_;
            $fix->emit($self, $label);
        });
    } else {
        my $var = $self->var;
        my $ref = $self->generate_var;
        $self->_captures->{$ref} = $fix;
        $perl = "${var} = ${ref}->fix(${var});";
    }

    $perl;
}

sub emit_block {
    my ($self, $cb) = @_;
    my $n = $self->_num_labels;
    $self->_num_labels($n + 1);
    my $label = "__FIX__${n}";
    my $perl = "${label}: {";
    $perl .= $cb->($label);
    $perl .= "};";
    $perl;
}

sub emit_clear_hash_ref {
    my ($self, $var) = @_;
    "undef %{${var}} if is_hash_ref(${var});";
}

sub emit_value {
    my ($self, $val) = @_;
    # Number should look like number and don't start with a 0 (no support for octals)
    is_number($val) && $val !~ /^0+/ ? $val : $self->emit_string($val);
}

sub emit_string {
    my ($self, $str) = @_;
    B::perlstring($str);
}

sub emit_match {
    my ($self, $pattern) = @_;
    $pattern =~ s/\//\\\//g;
    $pattern =~ s/\\$/\\\\/;
    "m/$pattern/";
}

sub emit_substitution {
    my ($self, $pattern, $replace) = @_;
    $pattern =~ s/\//\\\//g;
    $pattern =~ s/\\$/\\\\/;
    $replace =~ s/\//\\\//g;
    $replace =~ s/\\$/\\\\/;
    "s/$pattern/$replace/";
}

sub emit_declare_vars {
    my ($self, $var, $val) = @_;
    $var = "(".join(", ", @$var).")" if ref $var;
    $val = "(".join(", ", @$val).")" if ref $val;
    if (defined $val) {
        return "my ${var} = ${val};";
    }
    "my ${var};";
}

sub emit_new_scope {
    "{";
}

sub emit_end_scope {
    "};";
}

sub emit_foreach {
    my ($self, $var, $cb) = @_;
    my $perl = "";
    my $v = $self->generate_var;
    $perl .= "foreach (\@{${var}}) {";
    $perl .= $self->emit_declare_vars($v, '$_');
    $perl .= $cb->($v);
    $perl .= "}";
    $perl;
}

sub emit_foreach_key {
    my ($self, $var, $cb) = @_;
    my $perl = "";
    my $v = $self->generate_var;
    $perl .= "foreach (keys(\%{${var}})) {";
    $perl .= $self->emit_declare_vars($v, '$_');
    $perl .= $cb->($v);
    $perl .= "}";
    $perl;
}

sub emit_walk_path {
    my ($self, $var, $keys, $cb) = @_;

    $keys = [@$keys]; # protect keys

    if (@$keys) { # protect $var
        my $v = $self->generate_var;
        $self->emit_declare_vars($v, $var)
            . $self->_emit_walk_path($v, $keys, $cb);
    } else {
        $cb->($var);
    }
}

sub _emit_walk_path {
    my ($self, $var, $keys, $cb) = @_;

    @$keys || return $cb->($var);

    my $key = shift @$keys;
    my $str_key = $self->emit_string($key);
    my $perl = "";

    if ($key =~ /^\d+$/) {
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= "${var} = ${var}->{${str_key}};";
        $perl .= $self->_emit_walk_path($var, [@$keys], $cb);
        $perl .= "} elsif (is_array_ref(${var}) && \@{${var}} > ${key}) {";
        $perl .= "${var} = ${var}->[${key}];";
        $perl .= $self->_emit_walk_path($var, [@$keys], $cb);
        $perl .= "}";
    }
    elsif ($key eq '*') {
        my $v = $self->generate_var;
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= $self->emit_foreach($var, sub {
            return $self->_emit_walk_path(shift, $keys, $cb);
        });
        $perl .= "}";
    }
    else {
        if ($key eq '$first') {
            $perl .= "if (is_array_ref(${var}) && \@{${var}}) {";
            $perl .= "${var} = ${var}->[0];";
        }
        elsif ($key eq '$last') {
            $perl .= "if (is_array_ref(${var}) && \@{${var}}) {";
            $perl .= "${var} = ${var}->[\@{${var}} - 1];";
        }
        else {
            $perl .= "if (is_hash_ref(${var})) {";
            $perl .= "${var} = ${var}->{${str_key}};";
        }
        $perl .= $self->_emit_walk_path($var, $keys, $cb);
        $perl .= "}";
    }

    $perl;
}

sub emit_create_path {
    my ($self, $var, $keys, $cb) = @_;
    $self->_emit_create_path($var, [@$keys], $cb);
}

sub _emit_create_path {
    my ($self, $var, $keys, $cb) = @_;

    @$keys || return $cb->($var);

    my $key = shift @$keys;
    my $str_key = $self->emit_string($key);
    my $perl = "";

    if ($key =~ /^\d+$/) {
        my $v1 = $self->generate_var;
        my $v2 = $self->generate_var;
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= "my ${v1} = ${var};";
        $perl .= $self->_emit_create_path("${v1}->{${str_key}}", [@$keys], $cb);
        $perl .= "} elsif (is_maybe_array_ref(${var})) {";
        $perl .= "my ${v2} = ${var} //= [];";
        $perl .= $self->_emit_create_path("${v2}->[${key}]", [@$keys], $cb);
        $perl .= "}";
    }
    elsif ($key eq '*') {
        my $v1 = $self->generate_var;
        my $v2 = $self->generate_var;
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "my ${v1} = ${var};";
        $perl .= "for (my ${v2} = 0; ${v2} < \@{${v1}}; ${v2}++) {";
        $perl .= $self->_emit_create_path("${v1}->[${v2}]", $keys, $cb);
        $perl .= "}";
        $perl .= "}";
    }
    else {
        my $v = $self->generate_var;
        if ($key eq '$first' || $key eq '$last' || $key eq '$prepend' || $key eq '$append') {
            $perl .= "if (is_maybe_array_ref(${var})) {";
            $perl .= "my ${v} = ${var} //= [];";
            if ($key eq '$first') {
                    $perl .= $self->_emit_create_path("${v}->[0]", $keys, $cb);
            }
            elsif ($key eq '$last') {
                $perl .= "if (\@${v}) {";
                $perl .= $self->_emit_create_path("${v}->[\@${v} - 1]", [@$keys], $cb);
                $perl .= "} else {";
                $perl .= $self->_emit_create_path("${v}->[0]", [@$keys], $cb);
                $perl .= "}";
            }
            elsif ($key eq '$prepend') {
                $perl .= "if (\@${v}) {";
                $perl .= "unshift(\@${v}, undef);";
                $perl .= "}";
                $perl .= $self->_emit_create_path("${v}->[0]", $keys, $cb);
            }
            elsif ($key eq '$append') {
                $perl .= $self->_emit_create_path("${v}->[\@${v}]", $keys, $cb);
            }
            $perl .= "}";
        }
        else {
            $perl .= "if (is_maybe_hash_ref(${var})) {";
            $perl .= "my ${v} = ${var} //= {};";
            $perl .= $self->_emit_create_path("${v}->{${str_key}}", $keys, $cb);
            $perl .= "}";
        }
    }

    $perl;
}

sub emit_get_key {
    my ($self, $var, $key, $cb) = @_;

    return $cb->($var) unless defined $key;

    my $str_key = $self->emit_string($key);
    my $perl = "";

    if ($key =~ /^\d+$/) {
        $perl .= "if (is_hash_ref(${var}) && exists(${var}->{${str_key}})) {";
        $perl .= $cb->("${var}->{${str_key}}");
        $perl .= "} elsif (is_array_ref(${var}) && \@{${var}} > ${key}) {";
        $perl .= $cb->("${var}->[${key}]");
        $perl .= "}";
    }
    elsif ($key eq '$first') {
        $perl .= "if (is_array_ref(${var}) && \@{${var}}) {";
        $perl .= $cb->("${var}->[0]");
        $perl .= "}";
    }
    elsif ($key eq '$last') {
        $perl .= "if (is_array_ref(${var}) && \@{${var}}) {";
        $perl .= $cb->("${var}->[\@{${var}} - 1]");
        $perl .= "}";
    }
    elsif ($key eq '*') {
        my $i = $self->generate_var;
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "for (my ${i} = 0; ${i} < \@{${var}}; ${i}++) {";
        $perl .= $cb->("${var}->[${i}]", $i);
        $perl .= "}}";
    }
    else {
        $perl .= "if (is_hash_ref(${var}) && exists(${var}->{${str_key}})) {";
        $perl .= $cb->("${var}->{${str_key}}");
        $perl .= "}";
    }

    $perl;
}

sub emit_set_key {
    my ($self, $var, $key, $val) = @_;

    return "${var} = $val;" unless defined $key;

    my $perl = "";
    my $str_key = $self->emit_string($key);

    if ($key =~ /^\d+$/) {
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= "${var}->{${str_key}} = $val;";
        $perl .= "} elsif (is_array_ref(${var})) {";
        $perl .= "${var}->[${key}] = $val;";
        $perl .= "}";
    }
    elsif ($key eq '$first') {
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "${var}->[0] = $val;";
        $perl .= "}";
    }
    elsif ($key eq '$last') {
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "${var}->[\@{${var}} - 1] = $val;";
        $perl .= "}";
    }
    elsif ($key eq '$prepend') {
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "unshift(\@{${var}}, $val);";
        $perl .= "}";
    }
    elsif ($key eq '$append') {
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "push(\@{${var}}, $val);";
        $perl .= "}";
    }
    elsif ($key eq '*') {
        my $i = $self->generate_var;
        $perl .= "if (is_array_ref(${var})) {";
        $perl .= "for (my ${i} = 0; ${i} < \@{${var}}; ${i}++) {";
        $perl .= "${var}->[${i}] = $val;";
        $perl .= "}}";
    }
    else {
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= "${var}->{${str_key}} = $val;";
        $perl .= "}";
    }

    $perl;
}

sub emit_delete_key {
    my ($self, $var, $key, $cb) = @_;

    my $str_key = $self->emit_string($key);
    my $perl = "";
    my $vals;
    if ($cb) {
        $vals = $self->generate_var;
        $perl = $self->emit_declare_vars($vals, '[]');
    }

    if ($key =~ /^\d+$/) {
        $perl .= "if (is_hash_ref(${var}) && exists(${var}->{${str_key}})) {";
        $perl .= "push(\@{${vals}}, "                     if $cb;
        $perl .= "delete(${var}->{${str_key}})";
        $perl .= ")"                                      if $cb;
        $perl .= ";";
        $perl .= "} elsif (is_array_ref(${var}) && \@{${var}} > ${key}) {";
        $perl .= "push(\@{${vals}}, "                     if $cb;
        $perl .= "splice(\@{${var}}, ${key}, 1)";
        $perl .= ")"                                      if $cb;
    }
    elsif ($key eq '$first' || $key eq '$last' || $key eq '*') {
        $perl .= "if (is_array_ref(${var}) && \@{${var}}) {";
        $perl .= "push(\@{${vals}}, "                     if $cb;
        $perl .= "splice(\@{${var}}, 0, 1)"               if $key eq '$first';
        $perl .= "splice(\@{${var}}, \@{${var}} - 1, 1)"  if $key eq '$last';
        $perl .= "splice(\@{${var}}, 0, \@{${var}})"      if $key eq '*';
        $perl .= ")"                                      if $cb;
    }
    else {
        $perl .= "if (is_hash_ref(${var}) && exists(${var}->{${str_key}})) {";
        $perl .= "push(\@{${vals}}, "                    if $cb;
        $perl .= "delete(${var}->{${str_key}})";
        $perl .= ")"                                     if $cb;
    }
    $perl .= ";";
    $perl .= "}";
    if ($cb) {
        $perl .= $cb->($vals);
    }

    $perl;
}

sub emit_retain_key {
    my ($self, $var, $key) = @_;

    my $perl = "";

    if ($key =~ /^\d+$/) {
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= $self->emit_foreach_key($var, sub {
            my $v = shift;
            "delete(${var}->{${v}}) if ${v} ne ${key};";
        });
        $perl .= "} elsif (is_array_ref(${var})) {";
        $perl .= "if (\@{${var}} > ${key}) {";
        $perl .= "splice(\@{${var}}, 0, ${key});" if $key > 0;
        $perl .= "splice(\@{${var}}, 1, \@{${var}} - 1);";
        $perl .= "} else {";
        $perl .= "splice(\@{${var}}, 0, \@{${var}});";
        $perl .= "}";
        $perl .= "}";
    }
    elsif ($key eq '$first') {
        $perl .= "if (is_array_ref(${var}) && \@{${var}} > 1) {";
        $perl .= "splice(\@{${var}}, 1, \@{${var}} - 1);";
        $perl .= "}";
    }
    elsif ($key eq '$last') {
        $perl .= "if (is_array_ref(${var}) && \@{${var}} > 1) {";
        $perl .= "splice(\@{${var}}, 0, \@{${var}} - 1);";
        $perl .= "}";
    }
    elsif ($key eq '*') {
        # retain everything
    }
    else {
        $key = $self->emit_string($key);
        $perl .= "if (is_hash_ref(${var})) {";
        $perl .= $self->emit_foreach_key($var, sub {
            my $v = shift;
            "if ($v ne ${key}) {".
            "delete(${var}->{${v}});".
            "}";
        });
        $perl .= "}";
    }

    $perl;
}

sub emit_clone {
    my ($self, $var) = @_;
    "$var = clone($var);";
}

sub split_path {
    my ($self, $path) = @_;
    return [split /[\/\.]/, trim($path)];
}

=head1 NAME

Catmandu::Fix - a Catmandu class used for data crunching

=head1 SYNOPSIS

    use Catmandu::Fix;

    my $fixer = Catmandu::Fix->new(fixes => ['upcase("job")','remove_field("test")']);

    or

    my $fixer = Catmandu::Fix->new(fixes => ['fix_file.txt']);

    my $arr  = $fixer->fix([ ... ]);
    my $hash = $fixer->fix({ ... });

    my $it = Catmandu::Importer::YAML(file => '...');
    $fixer->fix($it)->each(sub {
        ...
    });

    or

    use Catmandu::Fix::upcase as => 'my_upcase';
    use Catmandu::Fix::remove_field as => 'my_remove';

    my $hash = { 'job' => 'librarian' , deep => { nested => '1'} };

    my_upcase($hash,'job');
    my_remove($hash,'deep.nested');

=head1 DESCRIPTION

Catmandu::Fixes can be used for easy data manipulation by non programmers. Using a
small Perl DSL language end-users can use Fix routines to manipulate data objects.
A plain text file of fixes can be created to specify all the routines needed to
tranform the data into the desired format.

=head1 PATHS

All the Fix routines in Catmandu::Fix use a TT2 type reference to point to values
in a Perl Hash. E.g. 'foo.2.bar' is a key 'bar' which is the 3-rd value of the
key 'foo'.

A special case is when you want to point to all items in an array. In this case
the wildcard '*' can be used. E.g. 'foo.*' points to all the items in the 'foo'
array.

For array values there are special wildcards available:

 * $append   - Add a new item at the end of an array
 * $prepend  - Add a new item at the start of an array
 * $first    - Syntactic sugar for index '0' (the head of the array)
 * $last     - Syntactic sugar for index '-1' (the tail of the array)

E.g.

 # Create { mods => { titleInfo => [ { 'title' => 'a title' }] } };
 add_field('mods.titleInfo.$append.title', 'a title');

 # Create { mods => { titleInfo => [ { 'title' => 'a title' } , { 'title' => 'another title' }] } };
 add_field('mods.titleInfo.$append.title', 'another title');

 # Create { mods => { titleInfo => [ { 'title' => 'foo' } , { 'title' => 'another title' }] } };
 add_field('mods.titleInfo.$first.title', 'foo');

 # Create { mods => { titleInfo => [ { 'title' => 'foo' } , { 'title' => 'bar' }] } };
 add_field('mods.titleInfo.$last.title', 'bar');

Read more about the Fix language at our Wiki: L<https://github.com/LibreCat/Catmandu/wiki/Fixes>

=head1 PUBLIC METHODS

=head2 new(fixes => [ FIX , ...])

Create a new Catmandu::Fix which will execute every FIX into a consecutive
order. A FIX can be the name of a Catmandu::Fix::* routine, or the path to a
plain text file containing all the fixes to be executed or a path to any
executable if L<Catmandu::Fix::cmd> is installed.

=head2 fix(HASH)

Execute all the fixes on a HASH. Returns the fixed HASH.

=head2 fix(ARRAY)

Execute all the fixes on every element in the ARRAY. Returns an ARRAY of fixes.

=head2 fix(Catmandu::Iterator)

Execute all the fixes on every item in an L<Catmandu::Iterator>. Returns a
(lazy) iterator on all the fixes.

=head2 fix(sub {})

Executes all the fixes on a generator function. Returns a new generator with fixed data.

=head2 log

Return the current logger. See L<Catmandu> for activating the logger in your main code.

=head1 EXTEND

One can extend the Fix language by creating own custom-made fixes. Two methods are
available to create an own Fix function:

  * Quick and easy: create a class that implements a C<fix> method.
  * Advanced: create a class that emits Perl code that will be evaled by the Fix module.

Both methods will be explained shortly.

=head2 Quick and easy

A Fix function is a Perl class in the C<Catmandu::Fix> namespace that implements a C<fix> method.
The C<fix> methods accepts a Perl hash as input and returns a (fixed) Perl hash as output. As
an example, the code belows implements the C<meow> Fix which inserts a 'meow' field with value 'purrrrr'.

    package Catmandu::Fix::meow;

    use Moo;

    sub fix {
        my ($self,$data) = @_;
        $data->{meow} = 'purrrrr';
        $data;
    }

    1;

Given this Perl class, the following fix statement can be used in your application:

    # Will add 'meow' = 'purrrrr' to the data
    meow()

Use the quick and easy method when your fixes are not dependent on reading or writing data
from/to a JSON path. Your Perl classes need to implement their own logic to read or write data
into the given Perl hash.

Fix arguments are passed as arguments to the C<new> function of the Perl class. As in

    # In the fix file...
    meow('test123', -count => 4)

    # ...will be translated into this pseudo code
    my $fix = Catmandu::Fix::meow->new('test123', '-count', 4);

Using L<Moo> these arguments can be catched with L<Catmandu::Fix::Has> package:

    package Catmandu::Fix::meow;

    use Catmandu::Sane;
    use Moo;
    use Catmandu::Fix::Has;

    has msg   => (fix_arg => 1); # required parameter 1
    has count => (fix_opt => 1, default => sub { 4 }); # optional parameter 'count' with default value 4

    sub fix {
        my ($self,$data) = @_;
        $data->{meow} = $self->msg x $self->count;
        $data;
    }

    1;

Using this code the fix statement can be used like:

    # Will add 'meow' = 'purrpurrpurrpurr'
    meow('purr', -count => 4)

=head2 Advanced

The advanced method is required when one needs to read or write values from/to deeply nested JSON paths.
One could parse JSON paths using the quick and easy Perl class above, but this would require a
lot of inefficient for-while loops. The advanced method emits Perl code that gets compiled.
This compiled code is evaled against all Perl hashes in the unput.The best
way to learn this method is by inspecting some example Fix commands.

To ease the implementation of Fixed that emit Perl code some helper methods are created. Many Fix functions
require a transformation of one or more values on a JSON Path. The L<Catmandu::Fix::SimpleGetValue>
provides an easy way to create such as script. In the example below we'll set the value at a JSON Path
to 'purrrrr':

    package Catmandu::Fix::purrrrr;

    use Catmandu::Sane;
    use Moo;
    use Catmandu::Fix::Has;

    has path => (fix_arg => 1);

    with 'Catmandu::Fix::SimpleGetValue';

    sub emit_value {
        my ($self, $var, $fixer) = @_;
        "${var} = 'purrrrr';";
    }

    1;

Run this command as:

    # Set the value(s) of an existing path to 'purrr'
    purrrrr(my.deep.nested.path)
    purrrrr(all.my.values.*)

Notice how the C<emit_value> of the Catmandu::Fix::purrrrr package returns Perl code and doesn't
operate directy on the Perl data. The parameter C<$var> contains only the name of a temporary variable
that will hold the value of the JSON path after compiling the code into Perl.

Use L<Catmandu::Fix::Has> to add more arguments to this fix:

    package Catmandu::Fix::purrrrr;

    use Catmandu::Sane;
    use Moo;
    use Catmandu::Fix::Has;

    has path => (fix_arg => 1);
    has msg  => (fix_opt => 1 , default => sub { 'purrrrr' });

    with 'Catmandu::Fix::SimpleGetValue';

    sub emit_value {
        my ($self, $var, $fixer) = @_;
        my $msg = $fixer->emit_string($self->msg);
        "${var} = ${msg};";
    }

    1;

Run this command as:

    # Set the value(s) of an existing path to 'okido'
    purrrrr(my.deep.nested.path, -msg => 'okido')
    purrrrr(all.my.values.*, -msg => 'okido')

Notice how the C<emit_value> needs to quote the C<msg> option using the emit_string function.

=head1 INTERNAL METHODS

This module provides several methods for writing fix packages. Usage can best
be understood by reading the code of existing fix packages.

=over

=item capture

=item emit_block

=item emit_clone

=item emit_clear_hash_ref

=item emit_create_path

=item emit_declare_vars

=item emit_delete_key

=item emit_fix

=item emit_fixes

=item emit_foreach

=item emit_foreach_key

=item emit_get_key

=item emit_reject

=item emit_retain_key

this method is DEPRECATED.

=item emit_set_key

=item emit_string

=item emit_value

=item emit_walk_path

=item generate_var

=item split_path

=back

=head1 SEE ALSO

Fixes are used by instances of L<Catmandu::Fixable> to manipulate items
L<Catmandu::Importer>, L<Catmandu::Exporter>, and L<Catmandu::Bag>.

=cut

1;
