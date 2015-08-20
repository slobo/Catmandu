package Catmandu::Fix::summate;

use Catmandu::Sane;
use Moo;
use Catmandu::Fix::Has;

with 'Catmandu::Fix::Base';
with 'Catmandu::Iterable';

has keys_path => (fix_arg => 1);
has vals_path => (fix_arg => 1);
has memo => (is => 'ro', default => sub { +{} });

sub emit {
    my ($self, $fixer) = @_;
    my $keys_path = $fixer->split_path($self->keys_path);
    my $vals_path = $fixer->split_path($self->vals_path);
    my $keys_key = pop @$keys_path;
    my $vals_key = pop @$vals_path;
    my $keys_var = $fixer->generate_var;
    my $vals_var = $fixer->generate_var;
    my $key_var = $fixer->generate_var;
    my $val_var = $fixer->generate_var;
    my $memo_var = $fixer->capture($self->memo);
    
    my $perl = $fixer->emit_declare_vars(
        [$keys_var, $vals_var],
        ['[]', '[]']
    );

    $perl .= $fixer->emit_walk_path($fixer->var, $keys_path, sub {
        my $var = shift;
        $fixer->emit_get_key($var, $keys_key, sub {
            my $var = shift;
            "push(\@{${keys_var}}, ${var}) if is_value(${var});";
        });
    });

    $perl .= "if (\@{${keys_var}}) {" .
        $fixer->emit_walk_path($fixer->var, $vals_path, sub {
            my $var = shift;
            $fixer->emit_get_key($var, $vals_key, sub {
                my $var = shift;
                "push(\@{${vals_var}}, ${var});";
            });
        }) .
    "}";

    $perl .= "while (\@{${keys_var}} && \@{${vals_var}}) {" .
        "my ${key_var} = shift(\@{${keys_var}});" .
        "my ${val_var} = shift(\@{${vals_var}});" .
        "if (is_positive(${val_var})) {" .
            "${memo_var}\->{${key_var}} += ${val_var};" .
        "}" .
    "}";

    $perl;
}

sub generator {
    my ($self) = @_;
    my $memo = $self->memo;
    sub {
        state $keys = [keys %$memo];
        my $key = shift(@$keys) // return; 
        my $val = $memo->{$key}; 
        +{$key => $val};
    }    
}

1;

