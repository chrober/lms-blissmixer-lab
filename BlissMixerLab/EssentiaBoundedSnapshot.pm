package Plugins::BlissMixerLab::EssentiaBoundedSnapshot;

use strict;
use warnings;

use DBI;
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();

# Two independent read-only SQLite transactions, NOT an atomic cross-DB
# generation. Host-owned generation/root provenance is a separate gate.
sub open_source {
    my ($path) = @_;
    die 'invalid absolute source path'
        unless defined($path) && !ref($path)
            && File::Spec->file_name_is_absolute($path)
            && -f $path && -r $path && !-l $path;
    my $db = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1, sqlite_open_flags => SQLITE_OPEN_READONLY,
    }) or die 'read-only source unavailable';
    $db->do('PRAGMA query_only = ON');
    $db->do('BEGIN');
    $db->selectrow_array('SELECT count(*) FROM sqlite_master');
    return $db;
}

# Project only an already verified seed+2..50 candidate cohort and one model
# into a private SQLite-v3 sidecar accepted by the unchanged native provider.
# This does not discover tracks, mutate source data or certify source generation.
sub project_features {
    my (%arg) = @_;
    my ($src, $rows, $model, $expected, $dest) =
        @arg{qw(source_dbh verified_tracks model_id expected_model_key destination)};
    die 'pinned source database required' unless $src;
    die 'complete bounded cohort required'
        unless ref($rows) eq 'ARRAY' && @$rows >= 3 && @$rows <= 51;
    die 'unsupported model' unless defined($model) && !ref($model)
        && ($model eq 'genre' || $model eq 'moodtheme');
    die 'invalid model fingerprint' unless defined($expected) && !ref($expected)
        && $expected =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'trusted output path required'
        unless defined($dest) && !ref($dest)
            && File::Spec->file_name_is_absolute($dest)
            && -d dirname($dest) && !-e $dest;
    die 'feature schema v3 required'
        unless $src->selectrow_array('PRAGMA user_version') == 3;

    my $dim = $model eq 'genre' ? 87 : 56;
    my $capability = $model eq 'genre' ? 'genre' : 'mood_theme';
    my $meta = $src->selectrow_hashref(q{
        SELECT model_key, preprocessing_version, aggregation, classes_json,
               validated_against_essentia
          FROM feature_models WHERE model_key = ? COLLATE BINARY
    }, undef, $expected);
    die 'missing exact model fingerprint' unless $meta;
    die 'oversize model labels' if length($meta->{classes_json} || '') > 128 * 1024;
    my $labels = eval { JSON::PP->new->decode($meta->{classes_json}) };
    die 'invalid model labels' unless ref($labels) eq 'ARRAY'
        && @$labels == $dim
        && !grep { !defined($_) || ref($_) || !length($_) } @$labels;
    my %names;
    die 'duplicate model labels' if grep { $names{$_}++ } @$labels;
    die 'invalid model metadata'
        unless defined($meta->{preprocessing_version}) && length($meta->{preprocessing_version})
            && defined($meta->{aggregation}) && length($meta->{aggregation})
            && defined($meta->{validated_against_essentia})
            && $meta->{validated_against_essentia} =~ /\A[01]\z/;

    my $stmt = $src->prepare(q{
        SELECT track_file, model_id, capability, model_key, scores_f32_le,
               typeof(scores_f32_le) AS storage_class
          FROM feature_tracks
         WHERE track_file = ? COLLATE BINARY AND model_id = ? COLLATE BINARY
    });
    my (%seen_ids, %seen_keys, @features);
    for my $item (@$rows) {
        die 'invalid verified key record' unless ref($item) eq 'HASH';
        my ($id, $key) = @$item{qw(track_id track_file)};
        die 'invalid or duplicate verified key'
            unless defined($id) && !ref($id) && length($id)
                && defined($key) && !ref($key) && length($key)
                && !$seen_ids{$id}++ && !$seen_keys{$key}++;
        $stmt->execute($key, $model);
        my $found = $stmt->fetchrow_hashref;
        die 'missing exact model head' unless $found;
        die 'duplicate model head' if $stmt->fetchrow_hashref;
        die 'incompatible feature row' unless $found->{track_file} eq $key
            && $found->{model_id} eq $model
            && $found->{model_key} eq $expected
            && $found->{capability} eq $capability
            && $found->{storage_class} eq 'blob'
            && defined($found->{scores_f32_le})
            && length($found->{scores_f32_le}) == $dim * 4;
        push @features, $found;
    }
    $stmt->finish;

    my $target = DBI->connect("dbi:SQLite:dbname=$dest", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
    }) or die 'bounded snapshot unavailable';
    my $ok = eval {
        $target->do('PRAGMA journal_mode=DELETE');
        $target->do('PRAGMA user_version=3');
        $target->do(q{
            CREATE TABLE feature_models(
              model_key TEXT PRIMARY KEY, preprocessing_version TEXT,
              aggregation TEXT, classes_json TEXT,
              validated_against_essentia INTEGER)
        });
        $target->do(q{
            CREATE TABLE feature_tracks(
              track_file TEXT NOT NULL, model_id TEXT NOT NULL,
              capability TEXT, model_key TEXT, scores_f32_le BLOB,
              PRIMARY KEY(track_file, model_id))
        });
        $target->do('BEGIN IMMEDIATE');
        $target->do('INSERT INTO feature_models VALUES (?,?,?,?,?)', undef,
            @$meta{qw(model_key preprocessing_version aggregation
                       classes_json validated_against_essentia)});
        my $insert = $target->prepare('INSERT INTO feature_tracks VALUES (?,?,?,?,?)');
        for my $head (@features) {
            $insert->bind_param(1, $head->{track_file});
            $insert->bind_param(2, $head->{model_id});
            $insert->bind_param(3, $head->{capability});
            $insert->bind_param(4, $head->{model_key});
            $insert->bind_param(5, $head->{scores_f32_le}, DBI::SQL_BLOB());
            $insert->execute;
        }
        $insert->finish;
        $target->do('COMMIT');
        $target->disconnect;
        die 'bounded snapshot exceeds 4 MiB' if -s $dest > 4 * 1024 * 1024;
        chmod 0400, $dest or die 'cannot seal bounded snapshot';
        1;
    };
    unless ($ok) {
        eval { $target->do('ROLLBACK'); $target->disconnect };
        unlink($dest);
        die 'bounded projection failed';
    }
    return { path => $dest, exported_tracks => scalar(@features) };
}

1;
