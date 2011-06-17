use strict;
use warnings;
use utf8;

return +{
    'create' => [
        title => [
            ['NOT_NULL', "タイトルが書かれていません" ],
        ],
        body => [
            ['NOT_NULL', "記事の内容が書かれていません" ],
        ],
        acl_view_mode => [
            ['NOT_NULL', "記事の公開範囲が指定されていません" ],
            [['CHOICE',qw/1 2 3/], "記事の公開範囲が正しくありません" ],
        ],
        acl_modify_mode => [
            ['NOT_NULL', "記事の編集権限が指定されていません" ],
            [['CHOICE',qw/2 3 4/], "記事の編集権限が正しくありません" ],
        ],
        anonymous => [
            ['NOT_NULL', "IDの表示が指定されていません" ],
            [['CHOICE',qw/0 1/], "IDの表示が正しくありません" ],
        ]
    ],

    'edit_limited' => [
        title => [
            ['NOT_NULL', "タイトルが書かれていません" ],
        ],
        body => [
            ['NOT_NULL', "記事の内容が書かれていません" ],
        ],
    ],

    'edit' => [
        title => [
            ['NOT_NULL', "タイトルが書かれていません" ],
        ],
        body => [
            ['NOT_NULL', "記事の内容が書かれていません" ],
        ],
        acl_view_mode => [
            ['NOT_NULL', "記事の公開範囲が指定されていません" ],
            [['CHOICE',qw/1 2 3/], "記事の公開範囲が正しくありません" ],
        ],
        acl_modify_mode => [
            ['NOT_NULL', "記事の編集権限が指定されていません" ],
            [['CHOICE',qw/2 3 4/], "記事の編集権限が正しくありません" ],
        ],
        anonymous => [
            ['NOT_NULL', "IDの表示が指定されていません" ],
            [['CHOICE',qw/0 1/], "IDの表示が正しくありません" ],
        ]
    ],

    'entry/comment' => [
        body => [
            ['NOT_NULL', "コメントの内容が書かれていません" ],
        ],
    ],
};

