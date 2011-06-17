create table users (
       id int unsigned not null auto_increment,
       openid varchar(255) not null,
       identity text,
       created_on datetime not null default '1970-01-01 00:00:00',
       updated_on timestamp not null,
       primary key (id),
       unique (openid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table user_networks (
       user_id int unsigned not null,
       openid varchar(255) not null,
       primary key (user_id, openid),
       key (openid),
       foreign key(user_id) references users(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table articles (
       id int unsigned not null auto_increment,
       rid varchar(16) not null,
       user_id int unsigned not null,
       title text,
       body text,
       converted_body text,
       acl_view_mode tinyint unsigned not null default '0',
       acl_modify_mode tinyint unsigned not null default '0',
       anonymous tinyint unsigned not null default '0',
       created_on datetime not null default '1970-01-01 00:00:00',
       updated_on timestamp not null,
       primary key (id),
       unique (rid),
       key (user_id, created_on),
       key (acl_view_mode),
       foreign key(user_id) references users(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table article_acl_view (
       article_id int unsigned not null,
       openid varchar(255) not null,
       user_id int unsigned not null,
       primary key (article_id, openid),
       key (user_id, openid),
       foreign key(article_id) references articles(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table article_acl_modify (
       article_id int unsigned not null,
       openid varchar(255) not null,
       user_id int unsigned not null,
       primary key (article_id, openid),
       key (user_id, openid),
       foreign key(article_id) references articles(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table article_history (
       id int unsigned not null auto_increment,
       article_id int unsigned not null,
       openid varchar(255) not null,
       updated_on timestamp not null,
       previous_body text,
       converted_diff text,
       primary key (id),
       key (article_id, updated_on),
       key (openid, updated_on),
       foreign key(article_id) references articles(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

create table comments (
       id int unsigned not null auto_increment,
       article_id int unsigned not null,
       openid varchar(255) not null,
       body text,
       converted_body text,
       created_on datetime not null default '1970-01-01 00:00:00',
       primary key (id),
       key (article_id, created_on),
       key (openid, created_on),
       foreign key(article_id) references articles(id) on delete cascade
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

