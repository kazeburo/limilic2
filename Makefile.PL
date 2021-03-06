use inc::Module::Install;
name 'Limilic';
all_from 'lib/Limilic.pm';

requires 'parent';
requires 'Scalar::Util';
requires 'Plack';
requires 'Plack::Builder::Conditionals';
requires 'Plack::Middleware::Static';
requires 'Plack::Middleware::Log::Minimal', 0.05;
requires 'Plack::Middleware::Scope::Container';
requires 'Plack::Middleware::ForceEnv';
requires 'Plack::Middleware::Deflater';
requires 'Plack::Middleware::ReverseProxy';
requires 'Router::Simple';
requires 'Cwd';
requires 'File::Basename';
requires 'Log::Minimal', 0.08;
requires 'Text::Xslate', 1.1003;
requires 'HTML::FillInForm::Lite';
requires 'Try::Tiny', 0.09;
requires 'Class::Accessor::Lite';
requires 'DBIx::Sunny', 0.13;
requires 'Math::BigInt::GMP';
requires 'Net::OpenID::Consumer';
requires 'YAML';
requires 'String::Random';
requires 'Text::Xatena';
requires 'Text::Diff';
requires 'DateTime';
requires 'DateTime::Format::Strptime';
requires 'Cache::Memcached::Fast';
requires 'LWP::UserAgent';
requires 'LWP::Protocol::https';
requires 'LWPx::ParanoidAgent';
requires 'Scope::Container::DBI';
requires 'DBD::mysql';
requires 'Digest::SHA';
requires 'XML::Feed';
requires 'JSON';
requires 'Starlet';
requires 'Server::Starter';

tests 't/*.t';
author_tests 'xt';

test_requires 'Test::More', 0.96;

auto_set_repository;
#auto_include;
WriteAll;
