use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Comed',
    AUTHOR              => 'Alexey Skorikov <alexey@skorikov.name>',
    VERSION             => 1.88,
    ABSTRACT_FROM       => 'lib/Comed.pm',
    PL_FILES            => {},
    MIN_PERL_VERSION    => 5.8.8,
    PREREQ_PM => {
        'AnyEvent'            => 5.21,
        'AnyEvent::HTTP'      => 1.45,
        'EV'                  => 3.9,
        'Twiggy'              => 0.1006,
        'Try::Tiny'           => 0.06,
        'JSON::XS'            => 2.26,
        'Config::General'     => 2.48,
        'Log::Dispatch'       => 2.26,
        'Test::More'          => 0,
        'Test::Pod'           => 1.14,
        'File::Temp'          => 0,
        'version'             => 0,
    },
    PREREQ_FATAL        => 1,
    EXE_FILES           => [qw| script/comed script/comedsend |],
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Comed-*' },
);
