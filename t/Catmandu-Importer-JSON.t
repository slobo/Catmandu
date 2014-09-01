#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Test::Exception;

my $pkg;
BEGIN {
    $pkg = 'Catmandu::Importer::JSON';
    use_ok $pkg;
}
require_ok $pkg;

my $data = [
   {name=>'Patrick',age=>'39'},
   {name=>'Nicolas',age=>'34'},
];

my $json = <<EOF;
{"name":"Patrick","age":"39"}
{"name":"Nicolas","age":"34"}
EOF

my $importer = $pkg->new(file => \$json);

isa_ok $importer, $pkg;

is_deeply $importer->to_array, $data;

$importer = $pkg->new(file => 't/512.json', multiline => 1);
ok $importer->to_array;

done_testing;
