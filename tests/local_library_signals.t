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

my @tracks = map { TestTrack->new($_) } qw(never recent old new five_years six_years missing);
my $day = 86400;
my $asOf = 3000 * $day;
my $profile = Plugins::BlissMixerLab::LocalLibrarySignals::prepare(
    \@tracks,
    -100,
    100,
    sub {
        return {
            never     => { lastPlayed => 0,             added => 2900 * $day },
            recent    => { lastPlayed => 2950 * $day,   added => 2990 * $day },
            old       => { lastPlayed => 500 * $day,    added => 100 * $day },
            new       => { lastPlayed => 800 * $day,    added => 2999 * $day },
            five_years => { lastPlayed => 800 * $day,   added => (3000 - 1825) * $day },
            six_years  => { lastPlayed => 800 * $day,   added => (3000 - 2190) * $day },
        };
    },
    $asOf,
    180,
    365,
);

ok($profile->{active}, 'non-zero local-library settings activate the profile');
ok($profile->{by_url}{never}{last_played_weight}
        > $profile->{by_url}{recent}{last_played_weight},
    'negative last-played influence favors tracks heard longer ago');
ok($profile->{by_url}{new}{library_age_weight}
        > $profile->{by_url}{old}{library_age_weight},
    'positive library-age influence favors more recently added tracks');
ok(abs($profile->{by_url}{six_years}{library_age_signal}
        - $profile->{by_url}{five_years}{library_age_signal})
        < abs($profile->{by_url}{five_years}{library_age_signal}
        - $profile->{by_url}{new}{library_age_signal}),
    'library-age signal saturates for similarly old tracks');
ok($profile->{by_url}{never}{last_played_signal} < -0.99,
    'never-played tracks are treated as maximally overdue');
is($profile->{last_played_horizon_days}, 180,
    'last-played horizon is retained in the prepared profile');
is($profile->{library_age_horizon_days}, 365,
    'library-age horizon is retained in the prepared profile');
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
