package Limilic::Schema;

use strict;
use warnings;
use utf8;
use parent qw/DBIx::Sunny::Schema/;
use Net::OpenID::Consumer;
use YAML;
use String::Random;
use Text::Xatena;
use Limilic::Xatena::Inline;
use Text::Diff;
use DateTime;
use DateTime::Format::Strptime;
use Mouse::Util::TypeConstraints;

subtype 'Uint'
    => as 'Int'
    => where { $_ >= 0 };
    
no Mouse::Util::TypeConstraints;

my $DTFMT = DateTime::Format::Strptime->new(
    time_zone => 'Asia/Tokyo',
    pattern   => '%Y-%m-%d %H:%M:%S',
);

sub convert_body {
    my $self = shift;
    my $body = shift;
    return if !defined $body;
    Text::Xatena->new(
        inline => Limilic::Xatena::Inline->new,
    )->format($body);
}

sub inflate_user {
    my $row = shift;
    my $identity = YAML::Load($row->{identity});
    $row->{identity} = Net::OpenID::VerifiedIdentity->new(
        consumer => Net::OpenID::Consumer->new,
        claimed_identity => Net::OpenID::ClaimedIdentity->new(
            identity => $row->{openid},
            semantic_info => {
                map { $_ => $identity->{$_} } qw/foaf foafmaker rss atom signed_fields/
            }
            )
    );
}

__PACKAGE__->select_row(
    'retrieve_user',
    id => 'Uint',
    q{SELECT * FROM users WHERE id=?},
    \&inflate_user
);

__PACKAGE__->select_row(
    'retrieve_openid_user',
    openid => 'Str',
    q{SELECT * FROM users WHERE openid=?},
    \&inflate_user
);

__PACKAGE__->query(
    'create_user',
    openid => 'Str',
    identity => {
        isa => 'Net::OpenID::VerifiedIdentity',
        deflater => sub {
            my $identity = shift;
            my %identity = map { $_ => $identity->$_ } 
                qw/foaf foafmaker rss atom signed_fields/;
            YAML::Dump(\%identity);
        },
    },
    created_on => {
        isa => 'DateTime',
        default => sub { DateTime->now( time_zone=>'Asia/Tokyo' ) },
        deflater => sub { $DTFMT->format_datetime(shift) },
    },
    q{INSERT INTO users (openid, identity, created_on) VALUES(?,?,?)}
);

__PACKAGE__->query(
    'update_openid_user',
    identity => {
        isa => 'Net::OpenID::VerifiedIdentity',
        deflater => sub {
            my $identity = shift;
            my %identity = map { $_ => $identity->$_ } 
                qw/foaf foafmaker rss atom signed_fields/;
            YAML::Dump(\%identity);
        },
    },
    openid => 'Str',
    q{UPDATE users SET identity = ? WHERE openid = ?}
);

__PACKAGE__->select_all(
    'retrieve_user_networks',
    user_id => 'Uint',
    q{SELECT * FROM user_networks WHERE user_id=?},
);

sub inflate_article {
    my ($row, $self) = @_;
    $row->{created_on} = $DTFMT->parse_datetime($row->{created_on});
    $row->{created_on}->set_time_zone("Asia/Tokyo");

    $row->{user} = $self->retrieve_user( id => $row->{user_id} );
    $row->{total_comments} = $self->select_one(q{SELECT COUNT(*) FROM comments WHERE article_id = ?}, $row->{id});

    $row->{can_modify} = sub {
        my $user = shift;
        return if ! $user;
        my $user_id = $row->{user_id};
        my $acl_modify_mode = $row->{acl_modify_mode};

        #only user
        return 1 if ( $user_id == $user->{id} );
        #listed user
        return 1 if ( $acl_modify_mode == 3
            && $self->select_row( 'SELECT * FROM article_acl_modify WHERE article_id =? AND openid =?',
                                  $row->{id}, $user->{openid} ) );
        #all user
        return 1 if ( $acl_modify_mode == 4 && $user->{openid} );

        return;
    };
    $row->{can_view} = sub {
        my $user = shift;
        return 1 if ( $row->{can_modify}->($user) );

        my $user_id = $row->{user_id};
        my $acl_view_mode = $row->{acl_view_mode};

        #all
        return 1 if ( $acl_view_mode == 1 );
        #private
        return 1 if ( $acl_view_mode == 2 && $user && $user->{id} == $user_id );

        #custom
        return 1 if ( $acl_view_mode == 3 
            && $user
            && $self->select_row( 'SELECT * FROM article_acl_view WHERE article_id =? AND openid =?',
                                  $row->{id}, $user->{openid} )
        );

        return;
    };
}

__PACKAGE__->select_row(
    'retrieve_article',
    id => 'Uint',
    q{SELECT * FROM articles WHERE id=?},
    \&inflate_article
);

__PACKAGE__->select_row(
    'retrieve_rid_article',
    rid => 'Str',
    q{SELECT * FROM articles WHERE rid=?},
    \&inflate_article
);

__PACKAGE__->query(
    'delete_article',
    id => 'Uint',
    q{DELETE FROM articles WHERE id=?},
);

__PACKAGE__->select_all(
    'recent_articles',
    'offset' => { isa => 'Uint', default => 0 },
    q{SELECT * FROM articles WHERE acl_view_mode = 1 ORDER BY id DESC LIMIT ?,11},
    \&inflate_article
);

__PACKAGE__->select_all(
    'user_articles',
    'user_id' => 'Uint',
    'offset' => { isa => 'Uint', default => 0 },
    q{SELECT * FROM articles WHERE user_id = ? ORDER BY id DESC LIMIT ?,11},
    \&inflate_article
);

__PACKAGE__->select_all(
    'article_acl_view',
    'article_id' => 'Uint',
    q{SELECT * FROM article_acl_view WHERE article_id = ?},
);

__PACKAGE__->select_all(
    'article_acl_modify',
    'article_id' => 'Uint',
    q{SELECT * FROM article_acl_modify WHERE article_id = ?},
);

__PACKAGE__->select_all(
    'article_histories',
    'article_id' => 'Uint',
    q{SELECT * FROM article_history WHERE article_id = ? ORDER BY id DESC LIMIT 10},
    sub {
        my ($row, $self) = @_;
        $row->{updated_on} = $DTFMT->parse_datetime($row->{updated_on});
        $row->{updated_on}->set_time_zone("Asia/Tokyo");
    }
);

sub inflate_comment {
    my ($row, $self) = @_;

    $row->{created_on} = $DTFMT->parse_datetime($row->{created_on});
    $row->{created_on}->set_time_zone("Asia/Tokyo");

    $row->{can_delete} = sub {
        my $user = shift;
        return if ( !$user );
        
        # writer
        return 1 if $row->{openid} eq $user->{openid};

        # article owner
        return 1 if $row->{user_id} == $user->{id};

        return;
    };
}

__PACKAGE__->select_all(
    'retrieve_article_comment',
    article_id => 'Uint',
    q{SELECT comments.*,articles.user_id FROM comments, articles
 WHERE comments.article_id = articles.id AND comments.article_id=? ORDER BY comments.created_on},
    \&inflate_comment,
);

__PACKAGE__->select_row(
    'retrieve_comment',
    id => 'Uint',
    article_id => 'Uint',
    q{SELECT comments.*,articles.user_id FROM comments, articles
 WHERE comments.article_id = articles.id AND comments.id=? AND comments.article_id = ?},
    \&inflate_comment,
);

__PACKAGE__->query(
    'delete_comment',
    id => 'Uint',
    q{DELETE FROM comments WHERE id = ?},
);

sub login_openid_user {
    my $self = shift;
    my $args = $self->args(
        'openid'  => 'Str',
        'identity' => 'Net::OpenID::VerifiedIdentity',
    );

    my $txn = $self->txn_scope;
    my $ret = $self->update_openid_user(
        openid => $args->{openid},
        identity => $args->{identity}
    );

    if ( $ret && $ret == 0 ) {
        $self->create_user(
            openid => $args->{openid},
            identity => $args->{identity}
        );
    }

    my $user = $self->retrieve_openid_user(
        openid => $args->{openid},
    );
    $txn->commit;
    $user;
}

sub add_user_networks {
    my $self = shift;
    my $args = $self->args(
        'user_id' => 'Uint',
        'openid'  => 'Str',
    );

    my $txn = $self->txn_scope;

    if ( $self->select_row(q{SELECT * FROM user_networks WHERE user_id = ? AND openid = ?},$args->{user_id},$args->{openid})  ) {
        $txn->commit;
        return;
    }

    $self->query(
        q{INSERT INTO user_networks (user_id, openid) VALUES(?,?)},
        $args->{user_id},
        $args->{openid}
    );

    $txn->commit;
}

sub create_article {
    my $self = shift;
    my $args = $self->args(
        rid => {
            isa => 'Str',
            default => sub { String::Random->new->randregex('[a-z0-9]{16}' ) }
        },
        user_id => 'Uint',
        title => 'Str',
        body => 'Str',
        acl_view_mode => 'Uint',
        acl_modify_mode => 'Uint',
        anonymous => 'Uint',
        created_on => {
            isa => 'DateTime',
            default => sub { $DTFMT->format_datetime(DateTime->now(time_zone=>'Asia/Tokyo')) },
        },
        acl_custom_view_openid => 'ArrayRef[Str]',
        acl_custom_modify_openid => 'ArrayRef[Str]',
    );

    my $converted_body = $self->converted_body($args->{body});

    my $txn = $self->txn_scope;
    $self->query(
        q{INSERT INTO articles 
 (rid, user_id, title, body, acl_view_mode, acl_modify_mode, anonymous, created_on, converted_body)
 VALUES (?,?,?,?,?,?,?,?)},
        map { $args->{$_} } qw/rid user_id title body acl_view_mode acl_modify_mode anonymous created_on/,
        $converted_body
    );

    my $article_id = $self->last_insert_id;

    for my $openid ( @{$args->{acl_custom_view_openid}} ) {
        $self->query(q{INSERT INTO article_acl_view (article_id,openid, user_id) VALUES (?,?,?)},
                     $article_id, $openid, $args->{user_id});
    }
    for my $openid ( @{$args->{acl_custom_modify_openid}} ) {
        $self->query(q{INSERT INTO article_acl_modify (article_id,openid, user_id) VALUES (?,?,?)},
                     $article_id, $openid, $args->{user_id});
    }

    $txn->commit;

    $args->{rid};
}


sub update_article_body {
    my $self = shift;
    my $args = $self->args(
        id => 'Uint',
        title => 'Str',
        body => 'Str',
        openid => 'Str',
    );

    my $converted_body = $self->converted_body($args->{body});

    my $txn = $self->txn_scope;
    my $article = $self->retrieve_article(id => $args->{id}) or creak('article not found');
    $self->query(
        'UPDATE articles SET title = ?, body = ?, converted_body WHERE id = ?',
        $args->{title}, $args->{body}, $converted_body, $args->{id});
    $self->add_article_history(
        article_id => $args->{id},
        openid => $args->{openid},
        previous_body => $article->{body},
        body => $args->{body},
    );
    
    $txn->commit;
}

sub add_article_history {
    my $self = shift;
    my $args = $self->args(
        article_id => 'Uint',
        openid => 'Str',
        previous_body => 'Str',
        body => 'Str',
    );
    my $previous = $args->{previous_body};
    my $body = $args->{body};
    my $diff = Text::Diff::diff( \$previous, \$body );
    my $converted_diff = $self->convert_body(<<"EOF");
>||
$diff
||<
EOF
    $self->query(
        'INSERT INTO article_history ( article_id, openid, previous_body, converted_diff ) VALUES (?, ?, ?, ?)',
        $args->{article_id}, $args->{openid}, $previous, $converted_diff
    );
}

sub update_article {
    my $self = shift;
    my $args = $self->args(
        id => 'Uint',
        title => 'Str',
        body => 'Str',
        acl_view_mode => 'Uint',
        acl_modify_mode => 'Uint',
        anonymous => 'Uint',
        acl_custom_view_openid => 'ArrayRef[Str]',
        acl_custom_modify_openid => 'ArrayRef[Str]',
        openid => 'Str',
        user_id => 'Uint',
    );

    my $converted_body = $self->convert_body($args->{body});

    my $txn = $self->txn_scope;
    my $article = $self->retrieve_article(id => $args->{id}) or creak('article not found');
    $self->query(
        'UPDATE articles SET title=?, body=?, converted_body = ?, acl_view_mode=?, acl_modify_mode=?, anonymous=?  WHERE id=?',
        $args->{title}, $args->{body}, $converted_body, $args->{acl_view_mode}, $args->{acl_modify_mode}, $args->{anonymous}, $args->{id});

    $self->query(q{DELETE FROM article_acl_view WHERE article_id = ?}, $args->{id});
    for my $openid ( @{$args->{acl_custom_view_openid}} ) {
        $self->query(q{INSERT INTO article_acl_view (article_id,openid, user_id) VALUES (?,?,?)},
                     $args->{id}, $openid, $args->{user_id});
    }
    $self->query(q{DELETE FROM article_acl_modify WHERE article_id = ?}, $args->{id});
    for my $openid ( @{$args->{acl_custom_modify_openid}} ) {
        $self->query(q{INSERT INTO article_acl_modify (article_id,openid, user_id) VALUES (?,?,?)},
                     $args->{id}, $openid, $args->{user_id});
    }

    $self->add_article_history(
        article_id => $args->{id},
        openid => $args->{openid},
        previous_body => $article->{body},
        body => $args->{body},
    );

    $txn->commit;
}

sub add_comment {
    my $self = shift;
    my $args = $self->args(
        article_id => 'Uint',
        openid => 'Str',
        body => 'Str',
        created_on => {
            isa => 'DateTime',
            default => sub { $DTFMT->format_datetime(DateTime->now( time_zone=>'Asia/Tokyo' )) },
        },
    );

    my $converted_body = $self->convert_body($args->{body});

    $self->query(
        q{INSERT INTO comments (article_id, openid, body, converted_body, created_on) VALUES (?, ?, ?, ?, ?)},
        $args->{article_id},
        $args->{openid},
        $args->{body},
        $converted_body,
        $args->{created_on},
    );
}


1;

