package Catmandu::Fix::get;

use Catmandu::Sane;
use Catmandu;
use Moo;
use Catmandu::Fix::Has;

has path => (fix_arg => 1);
has name => (fix_arg => 1);
has opts => (fix_opt => 'collect');

with 'Catmandu::Fix::SimpleGetValue';

sub emit_value {
    my ($self, $var, $fixer) = @_;
    my $name_var = $fixer->capture($self->name);
    my $opts_var = $fixer->capture($self->opts);
    my $temp_var = $fixer->generate_var;
    my $perl = $fixer->emit_declare_vars($temp_var);
    $perl .= "${temp_var} = Catmandu->importer(${name_var}, variables => ${var}, %{${opts_var}})->first;";
    $perl .= "if (defined(${temp_var})) {";
    $perl .= "${var} = ${temp_var};";
    $perl .= "}";
    $perl;
}

=head1 NAME

Catmandu::Fix::get - change the value of a HASH key or ARRAY index by replacing
it's value with imported data

=head1 SYNOPSIS

   get(foo.bar, JSON, url: "http://foo.com/bar.json", path: data.*)

=head1 SEE ALSO

L<Catmandu::Fix>

=cut

1;
