package Catmandu::FileBag;

use Catmandu::Sane;
use Moo::Role;
use Catmandu::Util qw(io);

before add => sub {
    my ($self, $data) = @_;
    $data->{_file} = io $data->{_file}, binmode => ':bytes';
};

1;

