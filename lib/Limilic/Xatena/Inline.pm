package Limilic::Xatena::Inline;

use strict;
use warnings;
use Text::Xatena::Inline::Base -Base;
use URI::Escape;
use HTML::Entities;
use Text::Xatena::Util;

match qr{\[\]([\s\S]*?)\[\]}i => sub {
    my ($self, $unlink) = @_;
    escape_html($unlink);
};

match qr{<!--.*-->} => sub {
    my ($self) = @_;
    '';
};

match qr{(<[^>]+>)}i => sub {
    my ($self, $tag) = @_;
    escape_html($tag);
};

match qr<\[((?:https?|ftp)://[^\s:]+(?::\d+)?[^\s:]+)(:(?:title(?:=([^[]+))?|barcode))?\]>i => sub {
    my ($self, $uri, $opt, $title) = @_;

    if ($opt) {
        if ($opt =~ /^:barcode$/) {
            return sprintf('<img src="http://chart.apis.google.com/chart?chs=150x150&cht=qr&chl=%s" title="%s"/>',
                uri_escape($uri),
                $uri,
            );
        }
        if ($opt =~ /^:title/) {
            return sprintf('<a href="%s">%s</a>',
                escape_html($uri),
                escape_html($title)
            );
        }
    } else {
        return sprintf('<a href="%s">%s</a>',
            escape_html($uri),
            escape_html($uri)
        );
    }

};

match qr<\[?((?:https?|ftp):(?!([^\s<>\]]+?):(?:barcode|title))([^\s<>\]]+))\]?>i => sub {
    my ($self, $uri) = @_;
    sprintf('<a href="%s">%s</a>',
        escape_html($uri),
        escape_html($uri)
    );
};

match qr<\[?mailto:([^\s\@:?]+\@[^\s\@:?]+(\?[^\s]+)?)\]?>i => sub {
    my ($self, $uri) = @_;
    sprintf('<a href="mailto:%s">%s</a>',
        escape_html($uri),
        escape_html($uri)
    );
};

match qr<\[tex:([^\]]+)\]>i => sub {
    my ($self, $tex) = @_;

    return sprintf('<img src="http://chart.apis.google.com/chart?cht=tx&chl=%s" alt="%s"/>',
        uri_escape($tex),
        escape_html($tex)
    );
};

1;
