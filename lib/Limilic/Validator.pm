package Limilic::Validator;

use strict;
use warnings;
use utf8;

our $VALIDATOR = {
    NOT_NULL => sub {
        return if not defined($_[0]);
        return if $_[0] eq "";
        return if ref($_[0]) eq 'ARRAY' && @$_ == 0;
        return 1;
    },
    CHOICE => sub {
        my ($val, @args) = @_;
        for my $c (@args) {
            if ($c eq $val) {
                return 1;
            }
        }
        return;
    }
};

sub new {
    my $class = shift;
    my $rules = shift;
    bless { rules => $rules }, $class;
}

sub validate {
    my $self = shift;
    my $req = shift;
    my $key = shift;
    my $rule = $self->{rules}->{$key};
    die "rule $key is not found" unless $rule;

    my @errors;
    for ( my $i=0; $i < @$rule; $i = $i+2 ) {
        my $param = $rule->[$i];
        my $constraints = $rule->[$i+1];
        PARAM_CONSTRAINT: for my $constraint ( @$constraints ) {
            if ( ref($constraint->[0]) eq 'ARRAY' ) {
                my @constraint = @{$constraint->[0]};
                my $constraint_name = shift @constraint;
                die "constraint:$constraint_name not found" if ! exists $VALIDATOR->{$constraint_name};
                if ( ! $VALIDATOR->{$constraint_name}->($req->param($param),@constraint) ) {
                    push @errors, $constraint->[1];
                    last PARAM_CONSTRAINT;
                }
            }
            elsif ( ref($constraint->[0]) eq 'CODE' ) {
                if ( ! $constraint->[0]->($req->param($param),$req) ) {
                    push @errors, $constraint->[1];
                    last PARAM_CONSTRAINT;
                }
            }
            else {
                die "constraint:".$constraint->[0]." not found" if ! exists $VALIDATOR->{$constraint->[0]};
                if ( ! $VALIDATOR->{$constraint->[0]}->($req->param($param)) ) {
                    push @errors, $constraint->[1];
                    last PARAM_CONSTRAINT;
                }
            }
        }
    }
    
    Limilic::Validator::Result->new(\@errors);
}

1;

package Limilic::Validator::Result;

use strict;
use warnings;
use utf8;

sub new {
    my $class = shift;
    my $errors = shift;
    bless $errors, $class;
}

sub has_error {
    return 1 if @{$_[0]};
    return;
}

sub messages {
    my @errors = @{$_[0]};
    \@errors;
}

1;


