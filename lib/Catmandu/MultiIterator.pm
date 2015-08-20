package Catmandu::MultiIterator;

use namespace::clean;
use Catmandu::Sane;
use Catmandu::Util qw(check_array_ref);
use Role::Tiny::With;

with 'Catmandu::Iterable';

sub new {
    bless check_array_ref($_[1]), $_[0];
}

sub generator {
    my ($self) = @_;
    sub {
        state $generators = [map { $_->generator } @$self];
        state $gen = shift @$generators;
        while ($gen) {
            if (defined(my $data = $gen->())) {
                return $data;
            } else {
                $gen = shift @$generators;
            }
        }
        return;
    };
}

1;

