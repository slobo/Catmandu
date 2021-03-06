package Catmandu::Fix::expand;

use Catmandu::Sane;
use Moo;
use CGI::Expand ();
use Catmandu::Fix::Has;

has sep => (fix_opt => 1, default => sub { undef });

sub fix {
	my ($self,$data) = @_;

	if (defined(my $char = $self->sep)) {
		my $new_ref = {};
		for my $key (keys %$data) {
			my $val = $data->{$key};
			$key =~ s{$char}{\.}g;
			$new_ref->{$key} = $val;
		}

		$data = $new_ref;
	}

    CGI::Expand->expand_hash($data);
}

=head1 NAME

Catmandu::Fix::expand - convert a flat hash into nested data using the TT2 dot convention

=head1 SYNOPSIS

   # collapse the data into a flat hash
   collapse()

   # expand again to the nested original
   expand()

   # optionally provide a path separator
   collapse(-sep => '/')
   expand(-sep => '/')

=head1 SEE ALSO

L<Catmandu::Fix>

=cut

1;
