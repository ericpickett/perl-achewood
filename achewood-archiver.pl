#!/usr/bin/env perl

use 5.18.2;
use open qw(:locale);
use strict;
use utf8;
use warnings qw(all);
use Cwd;
use Data::Dumper;

use Mojo::UserAgent;
use Mojo::Asset::File;
use Image::Magick;

my @urls;
my @img_urls;
my %img_extras;
my $base_url = 'http://achewood.com/';
my $home_page = $base_url . 'list.php';
my $max_connections = 30;
my $user_agent = Mojo::UserAgent->new(max_directs => 5);
my $active_connections = 0;

sub add_url {
  my $url_string = shift;
  my $url = Mojo::URL->new($url_string);
  push(@urls, $url);
}

sub format_timestamp {
  my $date = shift;
  $date =~ s/.*(\d{8})$/$1/;
  # convert from mmddyyyy to yyyy-mm-dd
  $date =~ s/^(\d{2})(\d{2})(\d{4})/$3-$1-$2/;

  return $date;
}

sub get_callback {
  my (undef, $tx) = @_;
  --$active_connections;
  if (not $tx->res->is_status_class(200)) {
    return;
  }
  my $url = $tx->req->url;
  if ($tx->res->headers->content_type =~ m{^text/html\b}ix) {
    parse_html($url, $tx);
  } elsif ($tx->res->headers->content_type =~ m{^image/gif\b}ix) {
    process_image($url, $tx);
  }
}

sub process_image {
  my ($url, $tx) = @_;
  my $date = format_timestamp($url);
  my $asset = $tx->res->content->asset->slurp;
  my $filename = getcwd() . "/comics/$date.gif";
  my $image = Image::Magick->new(
    magick =>'gif',
    background => 'white',
  );
  $image->BlobToImage($asset);
  my %font_parameters = get_font_parameters($date);
  my @font_metrics = $image->QueryMultilineFontMetrics(%font_parameters);
  my %corrected_geometry = get_corrected_image_geometry(\@font_metrics, $image);
  $image->Extent(
    geometry => $corrected_geometry{width} . 'x' . $corrected_geometry{height} . '-' . (($corrected_geometry{width} - $image->Get('width')) / 2) . '+0',
    background => 'white',
  );
  $image->Border(
    height => $corrected_geometry{border_height},
    bordercolor => 'white',
  );
  $font_parameters{x} = $corrected_geometry{font_x};
  $font_parameters{y} = $corrected_geometry{font_y};
  $image->Annotate(%font_parameters);
  $image->Extent(height => $corrected_geometry{height} + $corrected_geometry{border_height});
  $image->Opaque(
    color => 'none',
    fill => 'white',
    channel => 'All',
  );
  $image->Write(filename => $filename);
}

sub get_corrected_image_geometry {
  my ($font_metrics, $image) = @_;
=pod
  Font metrics return values
  0: character width
  1: character height
  2: ascender
  3: descender
  4: text width
  5: text height
  6: maximum horizontal advance
  7: bounds: x1
  8: bounds: y1
  9: bounds: x2
  10: bounds: y2
  11: origin: x
  12: origin: y
=cut
  my %corrected_geometry;
  $corrected_geometry{width} = $image->Get('width');
  $corrected_geometry{height} = $image->Get('height');
  $corrected_geometry{border_height} = $font_metrics->[5] + 10;
  if ($corrected_geometry{width} < $font_metrics->[4]) {
    $corrected_geometry{width} = $font_metrics->[4] + 10;
  }
  $corrected_geometry{font_x} = $corrected_geometry{width} / 2;
  $corrected_geometry{font_y} = ($font_metrics->[5] / 2 ) - 5;

  return %corrected_geometry;
}

sub get_font_parameters {
  my $date = shift;
  my $caption = $img_extras{$date}{caption};
  my $title = $img_extras{$date}{title};
  my $dateline = $img_extras{$date}{dateline};

  my %font_parameters = (
    text => "$dateline\n$title\n$caption",
    font => '/Library/Fonts/Verdana Italic.ttf',
    pointsize => 12,
    align => 'center',
  );
  return %font_parameters;
}

sub parse_html {
  my ($url, $tx) = @_;
  my $dom = $tx->res->dom;
  if ($url =~ /list\.php$/) {
    parse_list_page_html($dom);
  } else {
    parse_comic_page_html($dom, $url);
  }
}

sub parse_list_page_html {
  my $dom = shift;
  foreach my $comic_link ($dom->find('dd a')->each) {
    my $comic_url = $base_url . $comic_link->attr('href');
    my $title = $comic_link->text;
    my $date = format_timestamp($comic_url);
    $img_extras{$date} = { title => $title };
    add_url($comic_url);
    }
}

sub parse_comic_page_html {
  my ($dom, $url) = @_;
  my $comic = $dom->at('p#comic_body')->find('img')->[0];
  my $img_url = $base_url . $comic->attr('src');
  my $caption = $comic->attr('title');
  my $dateline = $dom->at('title')->text;
  my $date = format_timestamp($url);
  $img_extras{$date}{caption} = $caption;
  $img_extras{$date}{dateline} = $dateline;
  add_url($img_url);
}

# prime the pump
add_url($home_page);

Mojo::IOLoop->recurring(
  0 => sub {
    for ($active_connections + 1 .. $max_connections) {
      if (scalar(@urls) < 1) {
        return ($active_connections or Mojo::IOLoop->stop);
      }
      my $url = shift @urls;
      ++$active_connections;
      $user_agent->get($url => \&get_callback);
    }
  }
);

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
