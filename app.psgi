#!/usr/bin/perl

use FindBin;
use lib "$FindBin::Bin/lib";
use Limilic::Web;

Limilic::Web->psgi();
