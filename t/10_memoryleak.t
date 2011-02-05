#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use lib qw(blib/lib ../blib/lib blib/arch ../blib/arch);
use Test::More tests    => 3;
use Data::Dumper;
use Time::HiRes qw(time);
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";
    $Data::Dumper::Indent = 1;
    $Data::Dumper::Terse = 1;
    $Data::Dumper::Useqq = 1;
    $Data::Dumper::Deepcopy = 1;

    use_ok 'Data::StreamDeserializer';
}


sub gen_rand_object() {
    my $h = {};
    for (0 .. 20) {
        for (0 .. 20) {
            $h->{rand()} = [ map { "aa\\n" . rand } 0 .. 10 ];
        }
    }

    $h;
}

my $size;
my $size_end;
my $counter = 0;
my $i = 0;
my $len = 0;

my @tests = map { Dumper gen_rand_object  } 0 .. 20;
my $time = time;
for(;;)
{
    my $str = $tests[rand @tests];
    my $ds = new Data::StreamDeserializer data => $str;

    $i++ until $ds->next;
    $len+= length $str;

    if (time - $time > $counter and $counter < 5) {
        $size = Data::StreamDeserializer::_memory_size;
        $counter++;
    }

    if ($counter < 10) {
        if (time - $time > $counter and $counter >= 5) {
            $size_end = Data::StreamDeserializer::_memory_size;
            $counter++;
        }
    } else {
        $size_end = Data::StreamDeserializer::_memory_size;
        last;
    }

    last if Data::StreamDeserializer::_memory_size != $size;
}

ok $size_end == $size, "Check memory leak";
note "$i iterations were done, $len bytes were parsed";

$time = time;
$size = $size_end;
for (1 .. 20_000_000 + int rand 50_000_000) {
    push @tests, rand rand 1000;
    last if Data::StreamDeserializer::_memory_size != $size;
}
ok Data::StreamDeserializer::_memory_size != $size,
    sprintf "Check memory checker (size: %d elements) :)", scalar @tests;
