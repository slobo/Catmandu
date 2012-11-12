package Catmandu::FileStore::FS;

use Catmandu::Sane;
use Moo;

with 'Catmandu::Store', 'Catmandu::FileStore';

package Catmandu::FileStore::FS::Bag;

use Catmandu::Sane;
use Moo;
use Catmandu::Util qw(:io);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Find;

with 'Catmandu::Bag', 'Catmandu::FileBag', 'Catmandu::Serializer';

has path => (is => 'ro', required => 1, trigger => sub {
    my ($self, $path) = @_;
    make_path($path);
});

sub generator {
    my ($self) = @_;
}

sub get {
    my ($self, $id) = @_;
    my $path = segmented_path($id, base_path => $self->path);
    my $file_path = file_path($path, $id);
    -f $file_path || return;
    my $meta_path = "$file_path.metadata";
    my $data = $self->deserialize(read_file($meta_path));
    $data->{_file} = io($file_path, binmode => ':bytes');
    $data;
}

sub add {
    my ($self, $data) = @_;
    my $meta = {%$data};
    my $file = delete $meta->{_file};
    my $path = segmented_path($meta->{_id}, base_path => $self->path);
    my $file_path = file_path($path, $id);
    make_path($path);
    copy($file, $file_path);
    write_file("$file_path.metadata"), $self->serialize($meta));
    $data;
}

sub delete {
    my ($self, $id) = @_;
    my $path = segmented_path($id, base_path => $self->path);
    remove_tree($path);
}

sub delete_all {
    my ($self) = @_;
    remove_tree($self->path, {keep_root => 1});
}

1;
