#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Test::Exception;

my $pkg;
BEGIN {
    $pkg = 'Catmandu::Fix::trim';
    use_ok $pkg;
}

is_deeply
    $pkg->new('name')->fix({name => "\tjoe  "}),
    {name => "joe"},
    "trim horizontal whitespace";

is_deeply
    $pkg->new('name', 'whitespace')->fix({name => "\cK / joe  "}),
    {name => "/ joe"},
    "trim vertical whitespace";

is_deeply
    $pkg->new('name', 'nonword')->fix({name => "/\tjoe  .  "}),
    {name => "joe"},
    "trim nonword characters";

is_deeply
    $pkg->new('id', 'whitespace')->fix({id => " 0423985325   "}),
    {id => "0423985325"},
    "trim digit string";

is_deeply
    $pkg->new('name', 'whitespace')->fix({name => " 宮川   "}),
    {name => "宮川"},
    "trim utf8 string";

# TODO these are more a test of path matching than of trim
is_deeply
    $pkg->new('names.*.name')->fix({names => [{name => "\tjoe  "}, {name => "  rick  "}]}),
    {names => [{name => "joe"}, {name => "rick"}]},
    "trim wildcard array values";

is_deeply
    $pkg->new('names.*')->fix({names => {joe => "\tjoe  ", rick => "  rick  "}}),
    {names => {joe => "joe", rick => "rick"}},
    "trim wildcard hash values";

is_deeply
    $pkg->new('*')->fix({joe => "\tjoe  ", rick => "  rick  "}),
    {joe => "joe", rick => "rick"},
    "trim wildcard hash values at root";

done_testing;

