use strict;
use warnings;
use FindBin;
use Test::More;

use lib "$FindBin::Bin/..";

{
    package TestTrack;
    sub new {
        my ($class, $url) = @_;
        return bless { url => $url }, $class;
    }
    sub url { return $_[0]->{url} }
}

require Plugins::BlissMixerLab::LocalLibrarySignals;

my @tracks = map { TestTrack->new($_) } qw(never recent old new missing);
my $profile = Plugins::BlissMixerLab::LocalLibrarySignals::prepare(
    \@tracks,
    -100,
    100,
    sub {
        return {
            never  => { lastPlayed => 0,    added => 100 },
            recent => { lastPlayed => 2000, added => 200 },
            old    => { lastPlayed => 1000, added => 10  },
            new    => { lastPlayed => 1500, added => 300 },
        };
    },
);

ok($profile->{active}, 'non-zero local-library settings activate the profile');
ok($profile->{by_url}{never}{last_played_weight}
        > $profile->{by_url}{recent}{last_played_weight},
    'negative last-played influence favors tracks heard longer ago');
ok($profile->{by_url}{new}{library_age_weight}
        > $profile->{by_url}{old}{library_age_weight},
    'positive library-age influence favors more recently added tracks');
is($profile->{by_url}{missing}{combined_weight}, 1,
    'tracks absent from persistent metadata stay neutral');

my $neutral = Plugins::BlissMixerLab::LocalLibrarySignals::prepare(
    \@tracks,
    0,
    0,
    sub { die 'neutral settings must not read the database' },
);
ok(!$neutral->{active}, 'zero settings leave local-library reranking disabled');

done_testing();
