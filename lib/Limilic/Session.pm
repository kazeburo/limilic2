package Limilic::Session;

use strict;
use warnings;
use Class::Accessor::Lite (
    new => 1,
    ro => [qw/params/],
    rw => [q/logout/],
);

sub set {
    my $self = shift;
    $self->{params} ||= {};
    $self->{__modified}++;
    $self->{params}->{$_[0]} = $_[1];
}

sub get {
    my $self = shift;
    $self->{params} ||= {};
    $self->{params}->{$_[0]};
}

sub init {
    my $self = shift;
    $self->{params} = $_[0];
}

sub modified {
    $_[0]->{__modified};
}



1;

