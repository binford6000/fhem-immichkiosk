# $Id: 70_ImmichKiosk.pm 21 2026-11-12 15:42:02Z binford6000 $
##############################################################################
# 70_ImmichKiosk.pm
# Controls immich-kiosk (https://github.com/damongolding/immich-kiosk) from FHEM
# Note: this module was and is developed with AI assistance ("vibe coded", Claude by Anthropic).
#
# Copyright (C) 2026 binford6000
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
##############################################################################
package main;
use strict;
use warnings;
use HttpUtils;
use JSON::PP ();
use Encode qw(encode decode);
my $IK_VERSION = "0.5.7";
# raw Immich album lists per device (kept outside the device hash to keep "list" readable)
my %IK_RAW;
my %IK_SPECIAL = map { $_ => 1 } qw(all owned shared favorites);
my %IK_JS = (
  nextImage      => "document.querySelector('.navigation--next-asset')?.click();",
  prevImage      => "document.querySelector('.navigation--prev-asset')?.click();",
  addToFavorites      => "document.querySelector('.more-info--like-asset:not(.is-liked):not([disabled])')?.click();",
  removeFromFavorites => "document.querySelector('.more-info--like-asset.is-liked:not([disabled])')?.click();",
);
# default webCmd without / with Fully control
my $IK_WEBCMD      = "album";
my $IK_WEBCMD_FULL = "album:prevImage:nextImage:addToFavorites";
my $IK_CMDICON     = "prevImage:rc_PREVIOUS nextImage:rc_NEXT addToFavorites:scene_making_love_clean";
sub ImmichKiosk_Initialize {
  my ($hash) = @_;
  $hash->{DefFn}    = "ImmichKiosk_Define";
  $hash->{UndefFn}  = "ImmichKiosk_Undef";
  $hash->{DeleteFn} = "ImmichKiosk_Delete";
  $hash->{RenameFn} = "ImmichKiosk_Rename";
  $hash->{SetFn}    = "ImmichKiosk_Set";
  $hash->{GetFn}    = "ImmichKiosk_Get";
  $hash->{AttrFn}   = "ImmichKiosk_Attr";
  $hash->{NotifyFn} = "ImmichKiosk_Notify";
  $hash->{AttrList} = "disable:0,1 imageDuration imageBuffer layout:single,portrait,landscape,splitview,splitview-landscape "
                    . "rotationExclude:textField-long rotationMax rotationRetry progressInterval "
                    . "albumOrder:textField-long albumExclude:textField-long virtualAlbums:textField-long "
                    . "albumRefreshInterval urlParams fullyUrl " . $readingFnAttributes;
  return;
}
##############################################################################
# Define / Undef / Delete / Rename / Notify
##############################################################################
sub ImmichKiosk_Define {
  my ($hash, $def) = @_;
  my @a = split(/\s+/, $def);
  return "Usage: define <name> ImmichKiosk <immich-url> <kiosk-url>" if (@a != 4);
  return "immich-url '$a[2]' must start with http:// or https://" if ($a[2] !~ m{^https?://[^/\s]+});
  return "kiosk-url '$a[3]' must start with http:// or https://" if ($a[3] !~ m{^https?://[^/\s]+});
  $hash->{IMMICH_URL} = $a[2] =~ s{/+$}{}r;
  $hash->{KIOSK_URL}  = $a[3];
  $hash->{VERSION}    = $IK_VERSION;
  $hash->{NOTIFYDEV}  = "global";
  readingsSingleUpdate($hash, "state", "defined", 0) if (!defined(ReadingsVal($a[0], "state", undef)));
  # new device (not loaded from fhem.cfg): put it into its own room
  if ($init_done) {
    CommandAttr(undef, "$a[0] room ImmichKiosk") if (!AttrVal($a[0], "room", undef));
    CommandAttr(undef, "$a[0] webCmd $IK_WEBCMD") if (!AttrVal($a[0], "webCmd", undef));
    CommandAttr(undef, "$a[0] cmdIcon $IK_CMDICON") if (!AttrVal($a[0], "cmdIcon", undef));
    CommandAttr(undef, "$a[0] icon tablet") if (!AttrVal($a[0], "icon", undef));
  }
  ImmichKiosk_Startup($hash) if ($init_done);
  return;
}
sub ImmichKiosk_Undef {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  delete($IK_RAW{$name});
  return;
}
sub ImmichKiosk_Delete {
  my ($hash, $name) = @_;
  # remove all secrets of this device from the KeyValueStore
  setKeyValue("ImmichKiosk_${name}_$_", undef) for (qw(apiKey kioskPassword fullyPassword));
  return;
}
sub ImmichKiosk_Rename {
  my ($new, $old) = @_;
  $IK_RAW{$new} = delete($IK_RAW{$old});
  # move secrets to the new device name
  for my $k (qw(apiKey kioskPassword fullyPassword)) {
    my ($err, $val) = getKeyValue("ImmichKiosk_${old}_$k");
    next if ($err || !defined($val));
    setKeyValue("ImmichKiosk_${new}_$k", $val);
    setKeyValue("ImmichKiosk_${old}_$k", undef);
  }
  return;
}
sub ImmichKiosk_Notify {
  my ($hash, $dev) = @_;
  return if ($dev->{NAME} ne "global");
  my $events = deviceEvents($dev, 1);
  return if (!$events);
  ImmichKiosk_Startup($hash) if (grep { /^(INITIALIZED|REREADCFG)$/ } @{$events});
  return;
}
sub ImmichKiosk_Startup {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return if (IsDisabled($name));
  Log3($name, 4, "$name: startup, rotation " . ReadingsVal($name, "rotation", "off"));
  # leave state "disabled" after the attribute was removed
  readingsSingleUpdate($hash, "state", ReadingsVal($name, "album", "defined"), 1)
    if (ReadingsVal($name, "state", "") eq "disabled");
  # obsolete readings: rotationSlides (0.5.0, identical to albumSlides), albumPictures (0.5.4, now albumImages)
  for my $r (qw(rotationSlides albumPictures)) {
    readingsDelete($hash, $r) if (defined(ReadingsVal($name, $r, undef)));
  }
  ImmichKiosk_StartTimers($hash);
  ImmichKiosk_LoadAlbums($hash);
  # continue a running rotation after restart; needs no Immich access while the current album is running
  if (ReadingsVal($name, "rotation", "off") eq "on") {
    my $ts = ReadingsNum($name, ".rotationUntilTs", 0);
    if ($ts > time() + 5) {
      ImmichKiosk_RotateAt($hash, $ts);
      Log3($name, 3, "$name: rotation resumed until " . FmtDateTime($ts));
    }
    else {
      # expired: next album (includes reread and retry timer)
      ImmichKiosk_Rotate($hash, "next");
      return;
    }
  }
  ImmichKiosk_Reread($hash);
  return;
}
sub ImmichKiosk_StartTimers {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash, "ImmichKiosk_RefreshTimer");
  RemoveInternalTimer($hash, "ImmichKiosk_ProgressTimer");
  return if (IsDisabled($name));
  my $ri = AttrVal($name, "albumRefreshInterval", 0);
  InternalTimer(gettimeofday() + $ri, "ImmichKiosk_RefreshTimer", $hash) if ($ri > 0);
  my $pi = AttrVal($name, "progressInterval", 300);
  InternalTimer(gettimeofday() + $pi, "ImmichKiosk_ProgressTimer", $hash) if ($pi > 0);
  Log3($name, 4, "$name: timers: album refresh " . ($ri > 0 ? "every ${ri}s" : "off") . ", progress " . ($pi > 0 ? "every ${pi}s" : "off"));
  return;
}
sub ImmichKiosk_RefreshTimer {
  my ($hash) = @_;
  my $ri = AttrVal($hash->{NAME}, "albumRefreshInterval", 0);
  InternalTimer(gettimeofday() + $ri, "ImmichKiosk_RefreshTimer", $hash) if ($ri > 0);
  ImmichKiosk_Reread($hash);
  return;
}
##############################################################################
# Set / Get / Attr
##############################################################################
sub ImmichKiosk_Set {
  my ($hash, $name, $cmd, @args) = @_;
  return "\"set $name\" needs at least one argument" if (!defined($cmd));
  # secrets are never logged
  Log3($name, 4, "$name: set $cmd " . ($cmd =~ /^(apiKey|kioskPassword|fullyPassword)$/ ? (@args ? "***" : "(delete)") : join(" ", @args)))
    if ($cmd ne "?");
  ImmichKiosk_LoadAlbums($hash);
  my @usage = ("album:" . join(",", @{$hash->{helper}{order} // []}), "nextAlbum:noArg", "prevAlbum:noArg",
               "rotation:on,off", "reread:noArg", "apiKey", "kioskPassword", "fullyPassword");
  push(@usage, map { "$_:noArg" } sort keys %IK_JS) if (AttrVal($name, "fullyUrl", "") ne "");
  # secrets are always settable, even if the device is disabled
  if ($cmd =~ /^(apiKey|kioskPassword|fullyPassword)$/) {
    my $val = join(" ", @args);
    my $err = ImmichKiosk_SetSecret($hash, $cmd, $val eq "" ? undef : $val);
    return $err if ($err);
    ImmichKiosk_Reread($hash) if ($cmd eq "apiKey" && $val ne "");
    return;
  }
  my $known = grep { (split(/:/, $_))[0] eq $cmd } @usage;
  return "Unknown argument $cmd, choose one of " . join(" ", @usage) if (!$known);
  return "$name is disabled" if (IsDisabled($name) && !($cmd eq "rotation" && ($args[0] // "") eq "off"));
  my $noAlbums = "no albums loaded - check apiKey and reading lastError, then: set $name reread";
  if ($cmd eq "album") {
    return "usage: set $name album <name>" if (!@args);
    return $noAlbums if (!%{$hash->{helper}{albums} // {}});
    return ImmichKiosk_SelectAlbum($hash, $args[0], 0);
  }
  if ($cmd eq "nextAlbum" || $cmd eq "prevAlbum") {
    my $dir = $cmd eq "nextAlbum" ? 1 : -1;
    # rotation active: step within rotation instead of stopping it
    if (ReadingsVal($name, "rotation", "off") eq "on") {
      ImmichKiosk_Rotate($hash, $dir > 0 ? "next" : "prev");
      return;
    }
    my @l = @{$hash->{helper}{order} // []};
    return $noAlbums if (!@l);
    my $cur = ReadingsVal($name, "album", "");
    my ($i) = grep { $l[$_] eq $cur } 0 .. $#l;
    # unknown current album: next -> first, prev -> last
    $i = $dir > 0 ? -1 : 0 if (!defined($i));
    return ImmichKiosk_SelectAlbum($hash, $l[($i + $dir) % @l], 0);
  }
  if ($cmd eq "rotation") {
    return "usage: set $name rotation on|off" if (!@args || $args[0] !~ /^(on|off)$/);
    ImmichKiosk_Rotate($hash, $args[0] eq "on" ? "start" : "stop");
    return;
  }
  if ($cmd eq "reread") {
    return ImmichKiosk_Reread($hash);
  }
  if ($IK_JS{$cmd}) {
    readingsSingleUpdate($hash, "lastCommand", $cmd, 1);
    return ImmichKiosk_Fully($hash, "injectJavascript", { code => $IK_JS{$cmd} });
  }
  return;
}
sub ImmichKiosk_Get {
  my ($hash, $name, $cmd, @args) = @_;
  return "\"get $name\" needs at least one argument" if (!defined($cmd));
  Log3($name, 4, "$name: get $cmd") if ($cmd ne "?");
  if ($cmd eq "albums") {
    ImmichKiosk_LoadAlbums($hash);
    my $a = $hash->{helper}{albums} // {};
    return "no albums loaded - check apiKey and reading lastError, then: set $name reread" if (!%{$a});
    my $ret = sprintf("%-25s %7s  %s\n", "Album", "Assets", "ID(s)");
    for my $n (@{$hash->{helper}{order}}) {
      $ret .= sprintf("%-25s %7s  %s\n", $n, $a->{$n}{count} // "-", join(",", @{$a->{$n}{ids}}));
    }
    return $ret;
  }
  return "Unknown argument $cmd, choose one of albums:noArg";
}
sub ImmichKiosk_Attr {
  my ($cmd, $name, $attr, $val) = @_;
  my $hash = $defs{$name};
  Log3($name, 4, "$name: attr $cmd $attr" . ($cmd eq "set" ? " $val" : ""));
  if ($cmd eq "set") {
    my %int = (imageDuration => 1, imageBuffer => 0, rotationMax => 0, rotationRetry => 30,
               progressInterval => 0, albumRefreshInterval => 0);
    if (exists($int{$attr})) {
      return "$attr must be an integer >= $int{$attr}" if ($val !~ /^\d+$/ || $val < $int{$attr});
    }
    elsif ($attr eq "fullyUrl") {
      return "$attr must start with http:// or https://" if ($val !~ m{^https?://});
    }
    elsif ($attr eq "virtualAlbums") {
      for my $def (split(/\s+/, $val)) {
        return "invalid entry '$def', expected <name>=<album>,<album>,..." if ($def !~ /^[^=,:]+=[^=]+$/);
      }
    }
  }
  # extend / reduce the module's default webCmd; a user-defined webCmd is never touched
  if ($attr eq "fullyUrl" && $init_done) {
    my $wc = AttrVal($name, "webCmd", "");
    CommandAttr(undef, "$name webCmd $IK_WEBCMD_FULL") if ($cmd eq "set" && $wc eq $IK_WEBCMD);
    CommandAttr(undef, "$name webCmd $IK_WEBCMD") if ($cmd eq "del" && $wc eq $IK_WEBCMD_FULL);
  }
  # list-relevant attributes: rebuild with the new value (it is applied after this function returns)
  if ($attr =~ /^(virtualAlbums|albumOrder|albumExclude)$/ && $IK_RAW{$name}) {
    ImmichKiosk_BuildAlbums($hash, { $attr => $cmd eq "set" ? $val : "" });
    if ($attr eq "virtualAlbums" && $init_done) {
      # the current album may be a changed virtual album
      RemoveInternalTimer($hash, "ImmichKiosk_CurrentChanged");
      InternalTimer(gettimeofday() + 1, "ImmichKiosk_CurrentChanged", $hash);
    }
  }
  elsif ($attr =~ /^(layout|imageDuration|imageBuffer)$/ && $init_done) {
    # recalculate albumSlides / albumDuration with the new value
    RemoveInternalTimer($hash, "ImmichKiosk_StatsRefresh");
    InternalTimer(gettimeofday() + 1, "ImmichKiosk_StatsRefresh", $hash);
  }
  elsif ($attr =~ /^(albumRefreshInterval|progressInterval)$/ && $init_done) {
    # attribute value is applied after this function returns
    RemoveInternalTimer($hash, "ImmichKiosk_StartTimers");
    InternalTimer(gettimeofday() + 1, "ImmichKiosk_StartTimers", $hash);
  }
  elsif ($attr eq "disable" && $init_done) {
    if ($cmd eq "set" && $val) {
      RemoveInternalTimer($hash);
      readingsSingleUpdate($hash, "state", "disabled", 1);
    }
    else {
      # re-enabled: restart timers, rotation and reread after the attribute is removed
      RemoveInternalTimer($hash, "ImmichKiosk_Startup");
      InternalTimer(gettimeofday() + 1, "ImmichKiosk_Startup", $hash);
    }
  }
  return;
}
##############################################################################
# Immich: album list
##############################################################################
sub ImmichKiosk_Reread {
  my ($hash, $next) = @_;
  my $name = $hash->{NAME};
  return if (IsDisabled($name));
  my $key = ImmichKiosk_GetSecret($hash, "apiKey");
  return ImmichKiosk_Error($hash, "Immich", "apiKey not set - set $name apiKey <key>") if (!$key);
  ImmichKiosk_Http($hash, {
    url      => "$hash->{IMMICH_URL}/api/albums",
    timeout  => 10,
    method   => "GET",
    header   => "Accept: application/json\r\nx-api-key: $key",
    hash     => $hash,
    next     => $next,
    callback => \&ImmichKiosk_RereadCallback,
  });
  return;
}
sub ImmichKiosk_RereadCallback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $code = $param->{code} // 0;
  if ($err || $code != 200) {
    ImmichKiosk_Error($hash, "Immich", "album reread failed: " . ImmichKiosk_HttpMsg($param, $err, $data, "album.read"));
    return;
  }
  my $list = eval { JSON::PP::decode_json($data) };
  if (ref($list) ne "ARRAY") {
    ImmichKiosk_Error($hash, "Immich", "album reread failed: invalid response from $hash->{IMMICH_URL}");
    return;
  }
  ImmichKiosk_ClearError($hash, "Immich");
  $IK_RAW{$name} = $list;
  ImmichKiosk_BuildAlbums($hash, {});
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "lastReread", TimeNow());
  readingsBulkUpdate($hash, "state", ReadingsVal($name, "album", "ready"));
  readingsEndUpdate($hash, 1);
  if (ref($param->{next}) eq "CODE") {
    $param->{next}->();
  }
  else {
    # image count of the current album may have changed
    ImmichKiosk_StatsRefresh($hash);
  }
  return;
}
sub ImmichKiosk_BuildAlbums {
  my ($hash, $ov) = @_;
  my $name = $hash->{NAME};
  my $av   = sub { exists($ov->{$_[0]}) ? $ov->{$_[0]} : AttrVal($name, $_[0], $_[1]) };
  my %excl = map { $_ => 1 } split(/[\s,]+/, $av->("albumExclude", ""));
  my (%albums, @empty, @excluded);
  for my $al (@{$IK_RAW{$name} // []}) {
    # skip empty albums
    if (!$al->{assetCount} || !$al->{id}) {
      push(@empty, $al->{albumName} // "?");
      next;
    }
    my $n = ImmichKiosk_CleanName($al->{albumName});
    if ($n eq "" || $excl{$n}) {
      push(@excluded, $n eq "" ? ($al->{albumName} // "?") : $n);
      next;
    }
    my ($base, $i) = ($n, 2);
    while (exists($albums{$n})) {
      $n = "$base-$i";
      $i++;
    }
    $albums{$n} = { ids => [ $al->{id} ], count => $al->{assetCount}, label => encode("UTF-8", $al->{albumName} // "") };
  }
  my @real = sort keys %albums;
  for my $def (split(/\s+/, $av->("virtualAlbums", ""))) {
    my ($vname, $members) = split(/=/, $def, 2);
    next if (!defined($members) || $vname eq "");
    my (@ids, @miss, %seen);
    my $count = 0;
    my @m = split(/,/, $members);
    # special kiosk keyword (all, owned, shared, favorites)
    if (@m == 1 && $IK_SPECIAL{$m[0]}) {
      $albums{$vname} = { ids => [ $m[0] ], count => undef, label => $vname, virtual => 1 };
      next;
    }
    for my $p (@m) {
      my @hit;
      if ($p =~ /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i) {
        @hit = grep { $albums{$_}{ids}[0] eq $p } @real;
        push(@ids, $p) if (!@hit && !$seen{$p}++);
      }
      else {
        # prefix match, e.g. Istanbul -> Istanbul-2026
        @hit = grep { /^\Q$p\E/ } @real;
        push(@miss, $p) if (!@hit);
      }
      for my $h (@hit) {
        my $id = $albums{$h}{ids}[0];
        next if ($seen{$id}++);
        push(@ids, $id);
        $count += $albums{$h}{count};
      }
    }
    Log3($name, 3, "$name: virtual album $vname - not found: @miss") if (@miss);
    Log3($name, 4, "$name: virtual album $vname: " . scalar(@ids) . " album(s), $count images");
    $albums{$vname} = { ids => \@ids, count => $count, label => $vname, virtual => 1 } if (@ids);
  }
  Log3($name, 4, "$name: albums: " . scalar(@{$IK_RAW{$name} // []}) . " from Immich, " . scalar(keys %albums) . " selectable"
               . (@empty ? ", empty: " . join(",", @empty) : "") . (@excluded ? ", excluded/unnamed: " . join(",", @excluded) : ""));
  # pinned albums first (attribute order), rest alphabetical
  my @pinned = grep { exists($albums{$_}) } split(/[\s,]+/, $av->("albumOrder", ""));
  my %pin    = map { $_ => 1 } @pinned;
  my @order  = (@pinned, sort { lc($a) cmp lc($b) } grep { !$pin{$_} } keys %albums);
  $hash->{helper}{albums} = \%albums;
  $hash->{helper}{order}  = \@order;
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, "albumList", join(",", @order));
  readingsBulkUpdateIfChanged($hash, "albumCount", scalar(@order));
  # persistent via statefile, so albums are selectable after restart before the first reread
  readingsBulkUpdateIfChanged($hash, ".albumData", JSON::PP->new->canonical->encode(\%albums));
  readingsEndUpdate($hash, 1);
  return;
}
sub ImmichKiosk_LoadAlbums {
  my ($hash) = @_;
  return if ($hash->{helper}{albums});
  my $name = $hash->{NAME};
  my $a = eval { JSON::PP->new->decode(ReadingsVal($name, ".albumData", "")) };
  return if (ref($a) ne "HASH");
  $hash->{helper}{albums} = $a;
  $hash->{helper}{order}  = [ grep { exists($a->{$_}) } split(/,/, ReadingsVal($name, "albumList", "")) ];
  return;
}
##############################################################################
# Album selection / URL
##############################################################################
sub ImmichKiosk_SelectAlbum {
  # $stats: [images, slides] already calculated by the rotation
  my ($hash, $album, $fromRotation, $stats) = @_;
  my $name = $hash->{NAME};
  ImmichKiosk_LoadAlbums($hash);
  my $e = $hash->{helper}{albums}{$album};
  return "unknown album '$album'" if (!$e);
  # manual album change stops rotation
  if (!$fromRotation && ReadingsVal($name, "rotation", "off") eq "on") {
    Log3($name, 3, "$name: manual album change - stopping rotation");
    ImmichKiosk_Rotate($hash, "stop");
  }
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "album", $album);
  readingsBulkUpdate($hash, "albumId", join(",", @{$e->{ids}}));
  readingsBulkUpdate($hash, "url", ImmichKiosk_BuildUrl($hash, $e->{ids}, 0));
  readingsBulkUpdate($hash, "state", $album);
  readingsEndUpdate($hash, 1);
  Log3($name, 3, "$name: loading album $album");
  if ($stats) {
    ImmichKiosk_StatsUpdate($hash, $album, @{$stats});
  }
  else {
    ImmichKiosk_Stats($hash, $album, sub { ImmichKiosk_StatsUpdate($hash, $album, @_) });
  }
  return ImmichKiosk_SendUrl($hash, $e->{ids});
}
sub ImmichKiosk_BuildUrl {
  my ($hash, $ids, $withSecret) = @_;
  my $name = $hash->{NAME};
  my @p = map { "album=" . ImmichKiosk_UrlEnc($_) } @{$ids};
  my $dur = AttrVal($name, "imageDuration", "");
  push(@p, "duration=$dur") if ($dur ne "");
  my $layout = AttrVal($name, "layout", "");
  push(@p, "layout=$layout") if ($layout ne "");
  my $extra = AttrVal($name, "urlParams", "");
  $extra =~ s/^[?&]+//;
  push(@p, $extra) if ($extra ne "");
  if ($withSecret) {
    my $pw = ImmichKiosk_GetSecret($hash, "kioskPassword");
    push(@p, "password=" . ImmichKiosk_UrlEnc($pw)) if (defined($pw) && $pw ne "");
  }
  my $base = $hash->{KIOSK_URL};
  return $base . ($base =~ /\?/ ? "&" : "?") . join("&", @p);
}
sub ImmichKiosk_SendUrl {
  my ($hash, $ids) = @_;
  return if (AttrVal($hash->{NAME}, "fullyUrl", "") eq "");
  my $url = ImmichKiosk_BuildUrl($hash, $ids, 1);
  # store as start URL (survives tablet restarts), then load it
  return ImmichKiosk_Fully($hash, "setStringSetting", { key => "startURL", value => $url },
    sub { ImmichKiosk_Fully($hash, "loadStartURL", {}) });
}
##############################################################################
# Rotation: start | stop | next | prev | resume
##############################################################################
sub ImmichKiosk_Rotate {
  my ($hash, $cmd) = @_;
  my $name = $hash->{NAME};
  Log3($name, 4, "$name: rotation $cmd");
  if ($cmd eq "stop") {
    RemoveInternalTimer($hash, "ImmichKiosk_RotateTimer");
    # invalidate pending asynchronous rotation steps
    $hash->{helper}{rotGen}++;
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "rotation", "off");
    readingsBulkUpdate($hash, "rotationUntil", "-");
    readingsBulkUpdate($hash, "rotationDuration", "-");
    readingsBulkUpdate($hash, "rotationProgress", 0);
    readingsBulkUpdate($hash, ".rotationUntilTs", 0);
    readingsBulkUpdate($hash, ".rotationStartTs", 0);
    readingsEndUpdate($hash, 1);
    Log3($name, 3, "$name: rotation stopped");
    return;
  }
  readingsSingleUpdate($hash, "rotation", "on", 1) if ($cmd eq "start");
  return if (ReadingsVal($name, "rotation", "off") ne "on");
  # after restart: show the running album until its end
  if ($cmd eq "resume") {
    my $ts = ReadingsNum($name, ".rotationUntilTs", 0);
    if ($ts > time() + 5) {
      ImmichKiosk_RotateAt($hash, $ts);
      Log3($name, 3, "$name: rotation resumed until " . FmtDateTime($ts));
      return;
    }
  }
  # direction: start = 0 (keep current album), prev = -1, otherwise +1
  my $dir = $cmd eq "start" ? 0 : $cmd eq "prev" ? -1 : 1;
  my $gen = ++$hash->{helper}{rotGen};
  # fallback timer if Immich does not answer - replaced on success
  ImmichKiosk_RotateAt($hash, time() + AttrVal($name, "rotationRetry", 300));
  ImmichKiosk_Reread($hash, sub { ImmichKiosk_RotateNext($hash, $dir, $gen) });
  return;
}
sub ImmichKiosk_RotateAt {
  my ($hash, $ts) = @_;
  Log3($hash->{NAME}, 4, "$hash->{NAME}: rotation timer set to " . FmtDateTime($ts));
  RemoveInternalTimer($hash, "ImmichKiosk_RotateTimer");
  InternalTimer($ts, "ImmichKiosk_RotateTimer", $hash);
  return;
}
sub ImmichKiosk_RotateTimer {
  my ($hash) = @_;
  return if (IsDisabled($hash->{NAME}));
  ImmichKiosk_Rotate($hash, "next");
  return;
}
sub ImmichKiosk_RotationList {
  my ($hash) = @_;
  my %ex = map { $_ => 1 } split(/[\s,]+/, AttrVal($hash->{NAME}, "rotationExclude", ""));
  my $a  = $hash->{helper}{albums} // {};
  # real albums in list order, without virtual albums and exclusions
  return grep { !$a->{$_}{virtual} && !$ex{$_} } @{$hash->{helper}{order} // []};
}
sub ImmichKiosk_RotateNext {
  my ($hash, $dir, $gen) = @_;
  my $name = $hash->{NAME};
  return if ($gen != $hash->{helper}{rotGen} || ReadingsVal($name, "rotation", "off") ne "on");
  my @real = ImmichKiosk_RotationList($hash);
  if (!@real) {
    # retry timer of ImmichKiosk_Rotate stays active
    ImmichKiosk_Error($hash, "Immich", "rotation: no albums available (all excluded, virtual or empty)");
    return;
  }
  my $cur  = ReadingsVal($name, "album", "");
  my $keep = (!$dir && grep { $_ eq $cur } @real) ? 1 : 0;
  my $n;
  if ($keep) {
    $n = $cur;
  }
  else {
    $dir ||= 1;
    # position of the last rotation album; unknown -> next: first, prev: last
    my $last  = ReadingsVal($name, ".rotationLast", "");
    my ($pos) = grep { $real[$_] eq $last } 0 .. $#real;
    $pos = $dir > 0 ? -1 : 0 if (!defined($pos));
    $n = $real[($pos + $dir) % @real];
  }
  Log3($name, 4, "$name: rotation list (" . scalar(@real) . "): " . join(",", @real) . "; current $cur, last "
               . ReadingsVal($name, ".rotationLast", "-") . ", direction $dir -> $n" . ($keep ? " (kept)" : ""));
  ImmichKiosk_Stats($hash, $n, sub { ImmichKiosk_RotateApply($hash, { album => $n, keep => $keep, gen => $gen }, @_) });
  return;
}
##############################################################################
# Album statistics: images, slides (per layout), duration
##############################################################################
sub ImmichKiosk_Stats {
  # calls $cb->(images, slides); undef = unknown
  my ($hash, $album, $cb) = @_;
  my $name   = $hash->{NAME};
  my $e      = $hash->{helper}{albums}{$album} // return $cb->(undef, undef);
  my $layout = AttrVal($name, "layout", "single");
  my @ids    = @{$e->{ids}};
  my $fav    = (@ids == 1 && $ids[0] eq "favorites") ? 1 : 0;
  # other kiosk keywords (all, owned, shared): would require counting the whole library
  return $cb->(undef, undef) if (!$fav && $IK_SPECIAL{$ids[0]});
  # single: every asset is one slide, no EXIF query needed
  return $cb->($e->{count}, $e->{count}) if (!$fav && $layout eq "single");
  my $ctx = { album => $album, layout => $layout, cb => $cb, count => $e->{count}, fav => $fav,
              ids => $fav ? [undef] : [@ids], land => 0, port => 0, square => 0, page => 1 };
  ImmichKiosk_StatsFetch($hash, $ctx);
  return;
}
sub ImmichKiosk_StatsFetch {
  my ($hash, $ctx) = @_;
  my $key = ImmichKiosk_GetSecret($hash, "apiKey") // "";
  my %q   = (type => "IMAGE", withExif => JSON::PP::true(), size => 1000, page => 0 + $ctx->{page});
  if ($ctx->{fav}) {
    $q{isFavorite} = JSON::PP::true();
  }
  else {
    # one album per query: several albumIds would only match assets contained in all of them
    $q{albumIds} = [ $ctx->{ids}[0] ];
  }
  ImmichKiosk_Http($hash, {
    url      => "$hash->{IMMICH_URL}/api/search/metadata",
    method   => "POST",
    data     => JSON::PP->new->encode(\%q),
    timeout  => 15,
    header   => "x-api-key: $key\r\nContent-Type: application/json\r\nAccept: application/json",
    hash     => $hash,
    ctx      => $ctx,
    callback => \&ImmichKiosk_StatsParse,
  });
  return;
}
sub ImmichKiosk_StatsParse {
  my ($param, $err, $data) = @_;
  my $hash  = $param->{hash};
  my $ctx   = $param->{ctx};
  my $res   = (!$err && ($param->{code} // 0) == 200) ? eval { JSON::PP::decode_json($data) } : undef;
  my $items = (ref($res) eq "HASH" && ref($res->{assets}) eq "HASH") ? $res->{assets}{items} : undef;
  if (ref($items) ne "ARRAY") {
    my $msg = ($err || ($param->{code} // 0) != 200) ? ImmichKiosk_HttpMsg($param, $err, $data, "asset.read") : "invalid response";
    ImmichKiosk_Error($hash, "Immich", "image formats for $ctx->{album} not available ($msg), using asset count");
    return $ctx->{cb}->($ctx->{count}, $ctx->{count});
  }
  for my $as (@{$items}) {
    my $e = ref($as->{exifInfo}) eq "HASH" ? $as->{exifInfo} : {};
    my ($w, $h) = ($e->{exifImageWidth} // 0, $e->{exifImageHeight} // 0);
    # EXIF orientation 5-8 = rotated by 90 degrees -> swap width/height
    ($w, $h) = ($h, $w) if (($e->{orientation} // "") =~ /^[5-8]$/);
    # square or without EXIF dimensions: always shown as single slide
    if ($h > $w) {
      $ctx->{port}++;
    }
    elsif ($w > $h) {
      $ctx->{land}++;
    }
    else {
      $ctx->{square}++;
    }
  }
  my $next = $res->{assets}{nextPage};
  if (defined($next) && $next ne "") {
    $ctx->{page} = $next;
    return ImmichKiosk_StatsFetch($hash, $ctx);
  }
  # next album of a virtual album
  shift(@{$ctx->{ids}});
  if (@{$ctx->{ids}}) {
    $ctx->{page} = 1;
    return ImmichKiosk_StatsFetch($hash, $ctx);
  }
  my ($l, $p, $q) = @{$ctx}{qw(land port square)};
  my %slides = (
    portrait              => $p,
    landscape             => $l,
    # two portrait images share one slide
    splitview             => $l + $q + int(($p + 1) / 2),
    # two landscape images share one slide
    "splitview-landscape" => $p + $q + int(($l + 1) / 2),
  );
  my $slides = $slides{$ctx->{layout}} // ($l + $p + $q);
  Log3($hash->{NAME}, 4, "$hash->{NAME}: $ctx->{album}: landscape $l, portrait $p, square/unknown $q, layout $ctx->{layout} -> $slides slides");
  # favorites: number of favorite images; albums: asset count from Immich
  return $ctx->{cb}->($ctx->{fav} ? $l + $p + $q : $ctx->{count}, $slides);
}
sub ImmichKiosk_Secs {
  my ($hash, $slides) = @_;
  my $name = $hash->{NAME};
  return $slides * (AttrVal($name, "imageDuration", 60) + AttrVal($name, "imageBuffer", 0));
}
sub ImmichKiosk_FmtDur {
  my ($secs) = @_;
  # HH:MM, hours may exceed 24
  return sprintf("%02d:%02d", int($secs / 3600), int($secs % 3600 / 60));
}
sub ImmichKiosk_StatsUpdate {
  my ($hash, $album, $images, $slides) = @_;
  my $name = $hash->{NAME};
  Log3($name, 4, "$name: $album: images " . ($images // "-") . ", slides " . ($slides // "-"));
  # album changed in the meantime
  return if (ReadingsVal($name, "album", "") ne $album);
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "albumImages", $images // "-");
  readingsBulkUpdate($hash, "albumSlides", $slides // "-");
  readingsBulkUpdate($hash, "albumDuration", defined($slides) ? ImmichKiosk_FmtDur(ImmichKiosk_Secs($hash, $slides)) : "-");
  readingsEndUpdate($hash, 1);
  return;
}
sub ImmichKiosk_CurrentChanged {
  my ($hash) = @_;
  my $name  = $hash->{NAME};
  my $album = ReadingsVal($name, "album", "");
  my $e     = $hash->{helper}{albums}{$album};
  if ($album ne "" && !$e) {
    Log3($name, 3, "$name: current album $album no longer exists");
    return;
  }
  return if (!$e);
  # members changed: update albumId, url and display (no rotation stop, rotation never shows virtual albums)
  if (join(",", @{$e->{ids}}) ne ReadingsVal($name, "albumId", "")) {
    Log3($name, 3, "$name: members of current album $album changed, reloading");
    ImmichKiosk_SelectAlbum($hash, $album, 1);
    return;
  }
  ImmichKiosk_StatsRefresh($hash);
  return;
}
sub ImmichKiosk_StatsRefresh {
  my ($hash) = @_;
  my $album = ReadingsVal($hash->{NAME}, "album", "");
  return if ($album eq "" || !$hash->{helper}{albums}{$album});
  ImmichKiosk_Stats($hash, $album, sub { ImmichKiosk_StatsUpdate($hash, $album, @_) });
  return;
}
sub ImmichKiosk_RotateApply {
  my ($hash, $ctx, $images, $slides) = @_;
  my $name = $hash->{NAME};
  my $n    = $ctx->{album};
  # stopped or superseded in the meantime
  return if ($ctx->{gen} != $hash->{helper}{rotGen} || ReadingsVal($name, "rotation", "off") ne "on");
  my $s    = (!$slides || $slides < 1) ? 1 : $slides;
  my $secs = ImmichKiosk_Secs($hash, $s);
  my $max  = AttrVal($name, "rotationMax", 0);
  $secs = $max if ($max && $secs > $max);
  my $ts  = int(time() + $secs);
  my $dur = ImmichKiosk_FmtDur($secs);
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, ".rotationLast", $n);
  readingsBulkUpdate($hash, ".rotationStartTs", int(time()));
  readingsBulkUpdate($hash, ".rotationUntilTs", $ts);
  readingsBulkUpdate($hash, "rotationAlbum", $n);
  readingsBulkUpdate($hash, "rotationUntil", substr(FmtTime($ts), 0, 5));
  readingsBulkUpdate($hash, "rotationDuration", $dur);
  readingsBulkUpdate($hash, "rotationProgress", 0);
  readingsEndUpdate($hash, 1);
  ImmichKiosk_RotateAt($hash, $ts);
  if ($ctx->{keep}) {
    ImmichKiosk_StatsUpdate($hash, $n, $images, $slides);
  }
  else {
    ImmichKiosk_SelectAlbum($hash, $n, 1, [ $images, $slides ]);
  }
  Log3($name, 3, "$name: rotation - $n ($s slides, $dur) until " . FmtDateTime($ts) . ($ctx->{keep} ? " (current album)" : ""));
  return;
}
sub ImmichKiosk_ProgressTimer {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $pi   = AttrVal($name, "progressInterval", 300);
  InternalTimer(gettimeofday() + $pi, "ImmichKiosk_ProgressTimer", $hash) if ($pi > 0);
  my $p = 0;
  if (ReadingsVal($name, "rotation", "off") eq "on") {
    my $s = ReadingsNum($name, ".rotationStartTs", 0);
    my $e = ReadingsNum($name, ".rotationUntilTs", 0);
    if ($s > 0 && $e > $s) {
      $p = int((time() - $s) * 100 / ($e - $s));
      $p = 0   if ($p < 0);
      $p = 100 if ($p > 100);
    }
  }
  Log3($name, 5, "$name: rotation progress $p%");
  readingsSingleUpdate($hash, "rotationProgress", $p, 1) if (ReadingsVal($name, "rotationProgress", "") ne $p);
  return;
}
##############################################################################
# Fully Kiosk Browser REST API
##############################################################################
sub ImmichKiosk_Fully {
  my ($hash, $cmd, $args, $next) = @_;
  my $name = $hash->{NAME};
  my $base = AttrVal($name, "fullyUrl", "");
  return "attribute fullyUrl not set" if ($base eq "");
  $base =~ s{/+$}{};
  my $pw = ImmichKiosk_GetSecret($hash, "fullyPassword") // "";
  return ImmichKiosk_Error($hash, "Fully", "fullyPassword not set - set $name fullyPassword <pw>") if ($pw eq "");
  my $q  = "cmd=$cmd&type=json&password=" . ImmichKiosk_UrlEnc($pw);
  $q .= "&$_=" . ImmichKiosk_UrlEnc($args->{$_}) for (sort keys %{$args});
  ImmichKiosk_Http($hash, {
    url      => "$base/?$q",
    hideurl  => 1,
    timeout  => 10,
    method   => "GET",
    hash     => $hash,
    fullyCmd => $cmd,
    next     => $next,
    callback => \&ImmichKiosk_FullyCallback,
  });
  return;
}
sub ImmichKiosk_FullyCallback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $cmd  = $param->{fullyCmd};
  my $code = $param->{code} // 0;
  if ($err || $code != 200) {
    ImmichKiosk_Error($hash, "Fully", "$cmd failed: " . ($err ? "connection failed: $err" : "HTTP $code"));
    return;
  }
  my $res = eval { JSON::PP::decode_json($data) };
  if (ref($res) eq "HASH" && ($res->{status} // "") =~ /error/i) {
    # wrong password: Fully answers with status Error and a statustext
    ImmichKiosk_Error($hash, "Fully", "$cmd failed: " . ($res->{statustext} // "error") . " - check fullyPassword");
    return;
  }
  ImmichKiosk_ClearError($hash, "Fully");
  Log3($name, 4, "$name: Fully $cmd ok");
  $param->{next}->() if (ref($param->{next}) eq "CODE");
  return;
}
##############################################################################
# Helpers
##############################################################################
sub ImmichKiosk_CleanName {
  my ($n) = @_;
  $n //= "";
  # remove emojis
  $n =~ s/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}\x{20E3}]//g;
  # remove setList separators
  $n =~ s/[,:]+//g;
  $n =~ s/^\s+|\s+$//g;
  # spaces -> "-", "Abu Dhabi 2024" -> "Abu-Dhabi-2024"
  $n =~ s/\s+/-/g;
  return encode("UTF-8", $n);
}
sub ImmichKiosk_Error {
  my ($hash, $src, $msg) = @_;
  my $name = $hash->{NAME};
  $msg = "$src: $msg";
  # log a repeated error only at verbose 4
  my $new = ReadingsVal($name, "lastError", "") ne $msg;
  Log3($name, $new ? 2 : 4, "$name: $msg");
  readingsSingleUpdate($hash, "lastError", $msg, 1) if ($new);
  return $msg;
}
sub ImmichKiosk_ClearError {
  my ($hash, $src) = @_;
  my $name = $hash->{NAME};
  # only clear errors of the same source (Immich / Fully)
  return if (ReadingsVal($name, "lastError", "") !~ /^\Q$src\E:/);
  Log3($name, 3, "$name: $src ok again");
  readingsDelete($hash, "lastError");
  return;
}
sub ImmichKiosk_HttpMsg {
  my ($param, $err, $data, $perm) = @_;
  return "connection to $param->{url} failed: $err" if ($err);
  my $code = $param->{code} // 0;
  my $res  = eval { JSON::PP::decode_json($data // "") };
  # Immich error responses contain a message field
  my $detail = (ref($res) eq "HASH" && defined($res->{message}) && !ref($res->{message})) ? " ($res->{message})" : "";
  return "HTTP 401 - apiKey invalid$detail" if ($code == 401);
  return "HTTP 403 - apiKey lacks permission $perm$detail" if ($code == 403);
  return "HTTP $code$detail";
}
sub ImmichKiosk_Http {
  my ($hash, $param) = @_;
  my $name = $hash->{NAME};
  my $cb   = $param->{callback};
  # HttpUtils logs URL and request header (incl. x-api-key) at loglevel+1 under the global verbose: keep secrets out of the log
  $param->{loglevel} = 6;
  $param->{ikStart}  = gettimeofday();
  $param->{callback} = sub {
    my ($p, $err, $data) = @_;
    ImmichKiosk_LogMasked($hash, 4, sprintf("response %s: %s, %.2fs, %d bytes", $p->{url},
      $err ? "error $err" : "HTTP " . ($p->{code} // "?"), gettimeofday() - $p->{ikStart}, length($data // "")));
    ImmichKiosk_LogMasked($hash, 5, "response body: " . ImmichKiosk_Trunc($data));
    $cb->($p, $err, $data);
  };
  ImmichKiosk_LogMasked($hash, 4, "request " . ($param->{method} // "GET") . " $param->{url}");
  ImmichKiosk_LogMasked($hash, 5, "request body: $param->{data}") if (defined($param->{data}));
  HttpUtils_NonblockingGet($param);
  return;
}
sub ImmichKiosk_LogMasked {
  my ($hash, $lvl, $msg) = @_;
  my $name = $hash->{NAME};
  # check the level first: masking reads the KeyValueStore
  return if ($lvl > AttrVal($name, "verbose", AttrVal("global", "verbose", 3)));
  for my $k (qw(apiKey kioskPassword fullyPassword)) {
    my $v = ImmichKiosk_GetSecret($hash, $k);
    next if (!defined($v) || $v eq "");
    # plain, URL-encoded and double-encoded (kiosk URL inside the Fully URL)
    my $e1 = ImmichKiosk_UrlEnc($v);
    my $e2 = ImmichKiosk_UrlEnc($e1);
    $msg =~ s/\Q$_\E/***/g for ($v, $e1, $e2);
  }
  $msg =~ s/(password=)[^&\s:]*/$1***/gi;
  $msg =~ s/(password%3D)(?:(?!%26)[^&\s])*/$1***/gi;
  $msg =~ s/(x-api-key:\s*)\S+/$1***/gi;
  Log3($name, $lvl, "$name: $msg");
  return;
}
sub ImmichKiosk_Trunc {
  my ($s) = @_;
  $s //= "";
  return length($s) > 500 ? substr($s, 0, 500) . "... (" . length($s) . " bytes)" : $s;
}
sub ImmichKiosk_UrlEnc {
  my ($s) = @_;
  $s //= "";
  $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
  return $s;
}
sub ImmichKiosk_SetSecret {
  my ($hash, $key, $val) = @_;
  return setKeyValue("ImmichKiosk_$hash->{NAME}_$key", $val);
}
sub ImmichKiosk_GetSecret {
  my ($hash, $key) = @_;
  my ($err, $val) = getKeyValue("ImmichKiosk_$hash->{NAME}_$key");
  return $err ? undef : $val;
}
1;
=pod
=item device
=item summary controls immich-kiosk album selection and rotation via URL parameters
=item summary_DE steuert Albumauswahl und Rotation von immich-kiosk per URL-Parameter
=begin html

<a id="ImmichKiosk"></a>
<b>Module:</b> 70_ImmichKiosk.pm <b>Maintainer:</b> binford6000 <b>Forum:</b> <a href="https://forum.fhem.de/index.php?topic=145917.0">Multimedia</a><br>
<h3>Immich Kiosk Control</h3>
<ul>
  <u><b>ImmichKiosk - controls album selection and rotation of immich-kiosk</b></u><br>
  Controls an <a href="https://github.com/damongolding/immich-kiosk">immich-kiosk</a> slideshow.
  Albums are read from the Immich API; the selected album is passed to immich-kiosk as URL parameter,
  so the kiosk configuration file is never modified. Optionally the URL is sent to a
  Fully Kiosk Browser via its REST API.<br>
  Source: <a href="https://github.com/binford6000/fhem-immichkiosk">github.com/binford6000/fhem-immichkiosk</a><br>
  <b>Note:</b> this module was and is developed with AI assistance ("vibe coded", Claude by Anthropic).
  It is tested in the maintainer's own setup; use at your own risk.<br><br>
  <a id="ImmichKiosk-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ImmichKiosk &lt;immich-url&gt; &lt;kiosk-url&gt;</code><br>
    Example: <code>define kiosk ImmichKiosk http://immich.lan:2283 http://kiosk.lan:3000</code><br>
    Afterwards set the Immich API key:
    <code>set kiosk apiKey &lt;key&gt;</code>
  </ul><br>
  <a id="ImmichKiosk-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="ImmichKiosk-set-album"></a><code>album &lt;name&gt;</code><br>
      Selects an album or virtual album. Stops a running rotation.</li>
    <li><a id="ImmichKiosk-set-nextAlbum"></a><a id="ImmichKiosk-set-prevAlbum"></a><code>nextAlbum</code>, <code>prevAlbum</code><br>
      Without rotation: steps through the album list. With rotation: steps within the rotation.</li>
    <li><a id="ImmichKiosk-set-rotation"></a><code>rotation on|off</code><br>
      Automatic album rotation over all real albums (no virtual albums, no rotationExclude).
      <code>on</code> keeps the current album if it is part of the rotation.
      Display time per album: slides &times; (imageDuration + imageBuffer), limited by rotationMax.</li>
    <li><a id="ImmichKiosk-set-reread"></a><code>reread</code><br>
      Reloads the album list from Immich.</li>
    <li><a id="ImmichKiosk-set-apiKey"></a><code>apiKey &lt;key&gt;</code><br>
      Immich API key (Immich: Account Settings &rarr; API Keys). Required to read albums.
      Minimum permissions: <code>album.read</code> (album list) and <code>asset.read</code>
      (image orientation for the layout calculation and image count of favorites).
      A separate key for this module is recommended, independent of the key used by immich-kiosk.
      No write permissions are needed: addToFavorites / removeFromFavorites are executed by immich-kiosk
      with its own API key (kiosk config), not by this module.
      Stored in the FHEM KeyValueStore; without argument the value is deleted.</li>
    <li><a id="ImmichKiosk-set-kioskPassword"></a><code>kioskPassword &lt;pw&gt;</code><br>
      Only needed if immich-kiosk is protected with a password (<code>password</code> option in the
      kiosk config.yaml). immich-kiosk then expects it as URL parameter password; the module appends it to the
      URL sent to Fully. It is not shown in reading url.
      Stored in the FHEM KeyValueStore; without argument the value is deleted.</li>
    <li><a id="ImmichKiosk-set-fullyPassword"></a><code>fullyPassword &lt;pw&gt;</code><br>
      Password of the Fully Kiosk Browser Remote Administration. Only needed with attribute fullyUrl.
      Stored in the FHEM KeyValueStore; without argument the value is deleted.</li>
    <li><a id="ImmichKiosk-set-nextImage"></a><a id="ImmichKiosk-set-prevImage"></a><a id="ImmichKiosk-set-addToFavorites"></a><a id="ImmichKiosk-set-removeFromFavorites"></a><code>nextImage</code>, <code>prevImage</code>,
      <code>addToFavorites</code>, <code>removeFromFavorites</code><br>
      Only with attribute fullyUrl: clicks the corresponding kiosk control via Fully JavaScript injection.
      addToFavorites / removeFromFavorites use the like button of the kiosk more-info overlay; the favorite is
      set in Immich by immich-kiosk with its own API key, which needs the corresponding permission.</li>
  </ul><br>
  <a id="ImmichKiosk-get"></a>
  <b>Get</b>
  <ul>
    <li><a id="ImmichKiosk-get-albums"></a><code>albums</code><br>
      Lists all albums with asset count and ID(s).</li>
  </ul><br>
  <a id="ImmichKiosk-attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a id="ImmichKiosk-attr-disable"></a><code>disable 0|1</code></li>
    <li><a id="ImmichKiosk-attr-imageDuration"></a><code>imageDuration &lt;seconds&gt;</code><br>
      Display time per slide. Passed as URL parameter duration and used for the rotation time.
      Unset: no URL parameter (kiosk config applies), rotation is calculated with 60 seconds
      (kiosk default). If the kiosk config uses a different duration, set this attribute accordingly.</li>
    <li><a id="ImmichKiosk-attr-imageBuffer"></a><code>imageBuffer &lt;seconds&gt;</code><br>
      Additional time per slide for transitions and loading. Default: 0.</li>
    <li><a id="ImmichKiosk-attr-layout"></a><code>layout single|portrait|landscape|splitview|splitview-landscape</code><br>
      Kiosk layout. Passed as URL parameter layout and used to calculate the number of slides per album
      (albumSlides, albumDuration, rotationDuration, rotationUntil). Image orientation is determined via EXIF from Immich:
      <ul>
        <li>single: every asset is one slide</li>
        <li>portrait / landscape: only portrait / landscape images</li>
        <li>splitview: landscape + square + half of the portrait images</li>
        <li>splitview-landscape: portrait + square + half of the landscape images</li>
      </ul>
      Unset: no URL parameter (kiosk config applies), calculated like single.
      Note: kiosk switches splitview to splitview-landscape on devices in portrait orientation;
      the module cannot detect this.</li>
    <li><a id="ImmichKiosk-attr-rotationExclude"></a><code>rotationExclude &lt;album&gt; ...</code><br>
      Albums skipped by rotation, separated by comma or whitespace.</li>
    <li><a id="ImmichKiosk-attr-rotationMax"></a><code>rotationMax &lt;seconds&gt;</code><br>
      Maximum display time per album. 0 or unset: unlimited.</li>
    <li><a id="ImmichKiosk-attr-rotationRetry"></a><code>rotationRetry &lt;seconds&gt;</code><br>
      Retry interval if Immich does not answer. Default: 300.</li>
    <li><a id="ImmichKiosk-attr-progressInterval"></a><code>progressInterval &lt;seconds&gt;</code><br>
      Update interval of rotationProgress. 0 = off. Default: 300.</li>
    <li><a id="ImmichKiosk-attr-albumOrder"></a><code>albumOrder &lt;album&gt; ...</code><br>
      Albums listed first in this order, the rest follows alphabetically.</li>
    <li><a id="ImmichKiosk-attr-albumExclude"></a><code>albumExclude &lt;album&gt; ...</code><br>
      Albums hidden completely.</li>
    <li><a id="ImmichKiosk-attr-virtualAlbums"></a><code>virtualAlbums &lt;name&gt;=&lt;album&gt;,&lt;album&gt; ...</code><br>
      Combines albums into one entry. Members are album names (prefix match, e.g. Istanbul matches
      Istanbul-2026) or album IDs. A single kiosk keyword (all, owned, shared, favorites) is also possible.
      Example: <code>Favourites=favorites Holidays=Turkey-2026,Istanbul,Barcelona</code></li>
    <li><a id="ImmichKiosk-attr-albumRefreshInterval"></a><code>albumRefreshInterval &lt;seconds&gt;</code><br>
      Periodic reread of the album list. Every rotation step rereads anyway.</li>
    <li><a id="ImmichKiosk-attr-urlParams"></a><code>urlParams &lt;params&gt;</code><br>
      Additional static URL parameters, e.g. <code>image_fit=cover&amp;transition=fade</code></li>
    <li><a id="ImmichKiosk-attr-fullyUrl"></a><code>fullyUrl &lt;url&gt;</code><br>
      Fully Kiosk Browser REST endpoint, e.g. <code>http://10.3.3.50:2323</code>.
      If set, the kiosk URL is stored as Fully start URL and loaded, and the commands nextImage, prevImage,
      addToFavorites and removeFromFavorites become available.</li>
  </ul><br>
  <b>Logging</b>
  <ul>
    <code>attr &lt;name&gt; verbose 4</code>: program flow (set/get/attr, requests with HTTP status and duration,
    timers, rotation decisions, album list summary).<br>
    <code>attr &lt;name&gt; verbose 5</code>: additionally request and response bodies (truncated to 500 characters).<br>
    API key and passwords are always masked as ***, so logs can be posted as they are.
  </ul><br>
  <a id="ImmichKiosk-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code> - current album; defined / ready before the first selection, disabled if disabled</li>
    <li><code>lastError</code> - last error, prefixed with its source (Immich: / Fully:), e.g. missing apiKey,
      invalid apiKey (HTTP 401), missing permission (HTTP 403), connection errors, wrong fullyPassword.
      Deleted again after the next successful request to the same source.</li>
    <li><code>album</code> - selected album</li>
    <li><code>albumId</code> - Immich album ID(s) or kiosk keyword of the selected album</li>
    <li><code>albumImages</code> - number of assets of the selected album; favorites: number of favorite images;
      - for the kiosk keywords all, owned, shared</li>
    <li><code>albumSlides</code> - number of slides of the selected album according to attribute layout</li>
    <li><code>albumDuration</code> - time (HH:MM) to show all slides of the selected album once:
      albumSlides &times; (imageDuration + imageBuffer); independent of rotation</li>
    <li><code>albumList</code> - all selectable albums in list order</li>
    <li><code>albumCount</code> - number of selectable albums</li>
    <li><code>url</code> - kiosk URL of the selected album, without password</li>
    <li><code>lastReread</code> - time of the last successful album reread</li>
    <li><code>lastCommand</code> - last command sent to Fully (nextImage, prevImage, addToFavorites, removeFromFavorites)</li>
    <li><code>rotation</code> - on | off</li>
    <li><code>rotationAlbum</code> - album currently shown by the rotation</li>
    <li><code>rotationUntil</code> - time (HH:MM) of the next album change, - if off</li>
    <li><code>rotationDuration</code> - effective display time of the rotation album (HH:MM): albumDuration,
      limited by rotationMax; - if off</li>
    <li><code>rotationProgress</code> - progress of the rotation album in percent (0-100)</li>
    <li>hidden: <code>.albumData</code> - JSON with all albums incl. original Immich names (label),
      e.g. for menus; <code>.rotationLast</code>, <code>.rotationStartTs</code>,
      <code>.rotationUntilTs</code> - internal rotation state, used to resume after restart</li>
  </ul>
</ul>

=end html
=begin html_DE

<a id="ImmichKiosk"></a>
<b>Module:</b> 70_ImmichKiosk.pm <b>Maintainer:</b> binford6000 <b>Forum:</b> <a href="https://forum.fhem.de/index.php?topic=145917.0">Multimedia</a><br>
<h3>Immich Kiosk Steuerung</h3>
<ul>
  <u><b>ImmichKiosk - Steuert Albumauswahl und Rotation von immich-kiosk</b></u><br>
  Steuert eine <a href="https://github.com/damongolding/immich-kiosk">immich-kiosk</a>-Diashow.
  Die Alben werden &uuml;ber die Immich-API gelesen; das gew&auml;hlte Album wird immich-kiosk als URL-Parameter
  &uuml;bergeben, die Konfigurationsdatei des Kiosk wird nie ver&auml;ndert. Optional wird die URL per REST-API
  an einen Fully Kiosk Browser gesendet.<br>
  Quelle: <a href="https://github.com/binford6000/fhem-immichkiosk">github.com/binford6000/fhem-immichkiosk</a><br>
  <b>Hinweis:</b> Dieses Modul wurde und wird mit KI-Unterst&uuml;tzung entwickelt (&bdquo;vibe coded&ldquo;, Claude von Anthropic).
  Es ist im eigenen Setup des Maintainers getestet; Nutzung auf eigene Gefahr.<br><br>
  <a id="ImmichKiosk-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ImmichKiosk &lt;immich-url&gt; &lt;kiosk-url&gt;</code><br>
    Beispiel: <code>define kiosk ImmichKiosk http://immich.lan:2283 http://kiosk.lan:3000</code><br>
    Danach den Immich-API-Key setzen:
    <code>set kiosk apiKey &lt;key&gt;</code>
  </ul><br>
  <a id="ImmichKiosk-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="ImmichKiosk-set-album"></a><code>album &lt;name&gt;</code><br>
      W&auml;hlt ein Album oder virtuelles Album. Stoppt eine laufende Rotation.</li>
    <li><a id="ImmichKiosk-set-nextAlbum"></a><a id="ImmichKiosk-set-prevAlbum"></a><code>nextAlbum</code>, <code>prevAlbum</code><br>
      Ohne Rotation: bl&auml;ttert durch die Albumliste. Mit Rotation: bl&auml;ttert innerhalb der Rotation.</li>
    <li><a id="ImmichKiosk-set-rotation"></a><code>rotation on|off</code><br>
      Automatische Album-Rotation &uuml;ber alle echten Alben (ohne virtuelle Alben und rotationExclude).
      <code>on</code> beh&auml;lt das aktuelle Album, wenn es Teil der Rotation ist.
      Anzeigedauer je Album: Slides &times; (imageDuration + imageBuffer), begrenzt durch rotationMax.</li>
    <li><a id="ImmichKiosk-set-reread"></a><code>reread</code><br>
      L&auml;dt die Albumliste neu aus Immich.</li>
    <li><a id="ImmichKiosk-set-apiKey"></a><code>apiKey &lt;key&gt;</code><br>
      Immich-API-Key (Immich: Kontoeinstellungen &rarr; API-Schl&uuml;ssel). Wird zum Einlesen der Alben ben&ouml;tigt.
      Mindestberechtigungen: <code>album.read</code> (Albumliste) und <code>asset.read</code>
      (Bildausrichtung f&uuml;r die Layout-Berechnung und Bildanzahl der Favoriten).
      Empfohlen ist ein eigener Key f&uuml;r das Modul, unabh&auml;ngig vom Key von immich-kiosk.
      Schreibrechte sind nicht n&ouml;tig: addToFavorites / removeFromFavorites f&uuml;hrt immich-kiosk mit seinem
      eigenen API-Key (Kiosk-Konfiguration) aus, nicht dieses Modul.
      Wird im FHEM-KeyValueStore gespeichert; ohne Argument wird der Wert gel&ouml;scht.</li>
    <li><a id="ImmichKiosk-set-kioskPassword"></a><code>kioskPassword &lt;pw&gt;</code><br>
      Nur n&ouml;tig, wenn immich-kiosk mit einem Passwort gesch&uuml;tzt ist (<code>password</code> Option in der
      Kiosk config.yaml). immich-kiosk erwartet es dann als URL-Parameter password; das Modul h&auml;ngt es an die
      an Fully gesendete URL an. Im Reading url erscheint es nicht.
      Wird im FHEM-KeyValueStore gespeichert; ohne Argument wird der Wert gel&ouml;scht.</li>
    <li><a id="ImmichKiosk-set-fullyPassword"></a><code>fullyPassword &lt;pw&gt;</code><br>
      Passwort der Remote Administration des Fully Kiosk Browser. Nur n&ouml;tig mit Attribut fullyUrl.
      Wird im FHEM-KeyValueStore gespeichert; ohne Argument wird der Wert gel&ouml;scht.</li>
    <li><a id="ImmichKiosk-set-nextImage"></a><a id="ImmichKiosk-set-prevImage"></a><a id="ImmichKiosk-set-addToFavorites"></a><a id="ImmichKiosk-set-removeFromFavorites"></a><code>nextImage</code>, <code>prevImage</code>,
      <code>addToFavorites</code>, <code>removeFromFavorites</code><br>
      Nur mit Attribut fullyUrl: klickt das jeweilige Bedienelement des Kiosk per Fully-JavaScript-Injection.
      addToFavorites / removeFromFavorites nutzen den Like-Button im More-Info-Overlay des Kiosk; den Favoriten
      setzt immich-kiosk mit seinem eigenen API-Key in Immich, der daf&uuml;r die entsprechende Berechtigung braucht.</li>
  </ul><br>
  <a id="ImmichKiosk-get"></a>
  <b>Get</b>
  <ul>
    <li><a id="ImmichKiosk-get-albums"></a><code>albums</code><br>
      Listet alle Alben mit Bildanzahl und ID(s).</li>
  </ul><br>
  <a id="ImmichKiosk-attr"></a>
  <b>Attribute</b>
  <ul>
    <li><a id="ImmichKiosk-attr-disable"></a><code>disable 0|1</code></li>
    <li><a id="ImmichKiosk-attr-imageDuration"></a><code>imageDuration &lt;Sekunden&gt;</code><br>
      Anzeigedauer pro Slide. Wird als URL-Parameter duration &uuml;bergeben und f&uuml;r die Rotationsdauer genutzt.
      Nicht gesetzt: kein URL-Parameter (es gilt die Kiosk-Konfiguration), die Rotation wird mit 60 Sekunden
      berechnet (Kiosk-Standard). Nutzt die Kiosk-Konfiguration eine andere Dauer, das Attribut entsprechend setzen.</li>
    <li><a id="ImmichKiosk-attr-imageBuffer"></a><code>imageBuffer &lt;Sekunden&gt;</code><br>
      Zuschlag pro Slide f&uuml;r &Uuml;bergang und Ladezeit. Standard: 0.</li>
    <li><a id="ImmichKiosk-attr-layout"></a><code>layout single|portrait|landscape|splitview|splitview-landscape</code><br>
      Kiosk-Layout. Wird als URL-Parameter layout &uuml;bergeben und f&uuml;r die Berechnung der Slides je Album
      genutzt (albumSlides, albumDuration, rotationDuration, rotationUntil). Die Bildausrichtung wird per EXIF aus Immich ermittelt:
      <ul>
        <li>single: jedes Bild ist eine Slide</li>
        <li>portrait / landscape: nur Hoch- / Querformat-Bilder</li>
        <li>splitview: Querformat + Quadrat + die H&auml;lfte der Hochformat-Bilder</li>
        <li>splitview-landscape: Hochformat + Quadrat + die H&auml;lfte der Querformat-Bilder</li>
      </ul>
      Nicht gesetzt: kein URL-Parameter (es gilt die Kiosk-Konfiguration), Berechnung wie single.
      Hinweis: Kiosk schaltet splitview auf Ger&auml;ten im Hochformat auf splitview-landscape um;
      das kann das Modul nicht erkennen.</li>
    <li><a id="ImmichKiosk-attr-rotationExclude"></a><code>rotationExclude &lt;Album&gt; ...</code><br>
      Alben, die die Rotation &uuml;berspringt, getrennt durch Komma oder Leerzeichen.</li>
    <li><a id="ImmichKiosk-attr-rotationMax"></a><code>rotationMax &lt;Sekunden&gt;</code><br>
      Maximale Anzeigedauer pro Album. 0 oder nicht gesetzt: unbegrenzt.</li>
    <li><a id="ImmichKiosk-attr-rotationRetry"></a><code>rotationRetry &lt;Sekunden&gt;</code><br>
      Wiederholungsintervall, wenn Immich nicht antwortet. Standard: 300.</li>
    <li><a id="ImmichKiosk-attr-progressInterval"></a><code>progressInterval &lt;Sekunden&gt;</code><br>
      Aktualisierungsintervall von rotationProgress. 0 = aus. Standard: 300.</li>
    <li><a id="ImmichKiosk-attr-albumOrder"></a><code>albumOrder &lt;Album&gt; ...</code><br>
      Alben, die in dieser Reihenfolge vorn stehen; der Rest folgt alphabetisch.</li>
    <li><a id="ImmichKiosk-attr-albumExclude"></a><code>albumExclude &lt;Album&gt; ...</code><br>
      Alben, die komplett ausgeblendet werden.</li>
    <li><a id="ImmichKiosk-attr-virtualAlbums"></a><code>virtualAlbums &lt;Name&gt;=&lt;Album&gt;,&lt;Album&gt; ...</code><br>
      Fasst Alben zu einem Eintrag zusammen. Mitglieder sind Albumnamen (Pr&auml;fix-Match, z.B. Istanbul trifft
      Istanbul-2026) oder Album-IDs. Ein einzelnes Kiosk-Schl&uuml;sselwort (all, owned, shared, favorites) ist
      ebenfalls m&ouml;glich.
      Beispiel: <code>Favoriten=favorites Urlaub=T&uuml;rkei-2026,Istanbul,Barcelona</code></li>
    <li><a id="ImmichKiosk-attr-albumRefreshInterval"></a><code>albumRefreshInterval &lt;Sekunden&gt;</code><br>
      Periodisches Neueinlesen der Albumliste. Jeder Rotationsschritt liest ohnehin neu ein.</li>
    <li><a id="ImmichKiosk-attr-urlParams"></a><code>urlParams &lt;Parameter&gt;</code><br>
      Zus&auml;tzliche feste URL-Parameter, z.B. <code>image_fit=cover&amp;transition=fade</code></li>
    <li><a id="ImmichKiosk-attr-fullyUrl"></a><code>fullyUrl &lt;url&gt;</code><br>
      REST-Endpunkt des Fully Kiosk Browser, z.B. <code>http://10.3.3.50:2323</code>.
      Wenn gesetzt, wird die Kiosk-URL als Fully-Start-URL gespeichert und geladen, und die Befehle nextImage, prevImage,
      addToFavorites und removeFromFavorites stehen zur Verf&uuml;gung.</li>
  </ul><br>
  <b>Logging</b>
  <ul>
    <code>attr &lt;name&gt; verbose 4</code>: Programmablauf (set/get/attr, Anfragen mit HTTP-Status und Dauer,
    Timer, Rotationsentscheidungen, Zusammenfassung der Albumliste).<br>
    <code>attr &lt;name&gt; verbose 5</code>: zus&auml;tzlich Request- und Response-Bodies (gek&uuml;rzt auf 500 Zeichen).<br>
    API-Key und Passw&ouml;rter werden immer als *** maskiert, Logs k&ouml;nnen also unver&auml;ndert gepostet werden.
  </ul><br>
  <a id="ImmichKiosk-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code> - aktuelles Album; defined / ready vor der ersten Auswahl, disabled wenn deaktiviert</li>
    <li><code>lastError</code> - letzter Fehler mit Quelle als Pr&auml;fix (Immich: / Fully:), z.B. fehlender apiKey,
      ung&uuml;ltiger apiKey (HTTP 401), fehlende Berechtigung (HTTP 403), Verbindungsfehler, falsches fullyPassword.
      Wird nach der n&auml;chsten erfolgreichen Anfrage an dieselbe Quelle wieder gel&ouml;scht.</li>
    <li><code>album</code> - gew&auml;hltes Album</li>
    <li><code>albumId</code> - Immich-Album-ID(s) oder Kiosk-Schl&uuml;sselwort des gew&auml;hlten Albums</li>
    <li><code>albumImages</code> - Bildanzahl des gew&auml;hlten Albums; Favoriten: Anzahl der Favoriten-Bilder;
      - bei den Kiosk-Schl&uuml;sselw&ouml;rtern all, owned, shared</li>
    <li><code>albumSlides</code> - Anzahl Slides des gew&auml;hlten Albums gem&auml;&szlig; Attribut layout</li>
    <li><code>albumDuration</code> - Dauer (HH:MM), bis alle Slides des gew&auml;hlten Albums einmal gezeigt wurden:
      albumSlides &times; (imageDuration + imageBuffer); unabh&auml;ngig von der Rotation</li>
    <li><code>albumList</code> - alle w&auml;hlbaren Alben in Listenreihenfolge</li>
    <li><code>albumCount</code> - Anzahl der w&auml;hlbaren Alben</li>
    <li><code>url</code> - Kiosk-URL des gew&auml;hlten Albums, ohne Passwort</li>
    <li><code>lastReread</code> - Zeitpunkt des letzten erfolgreichen Einlesens</li>
    <li><code>lastCommand</code> - letzter an Fully gesendeter Befehl (nextImage, prevImage, addToFavorites, removeFromFavorites)</li>
    <li><code>rotation</code> - on | off</li>
    <li><code>rotationAlbum</code> - von der Rotation aktuell gezeigtes Album</li>
    <li><code>rotationUntil</code> - Uhrzeit (HH:MM) des n&auml;chsten Albumwechsels, - wenn aus</li>
    <li><code>rotationDuration</code> - tats&auml;chliche Anzeigedauer des Rotationsalbums (HH:MM): albumDuration,
      begrenzt durch rotationMax; - wenn aus</li>
    <li><code>rotationProgress</code> - Fortschritt des Rotationsalbums in Prozent (0-100)</li>
    <li>versteckt: <code>.albumData</code> - JSON mit allen Alben inkl. Original-Immich-Namen (label),
      z.B. f&uuml;r Men&uuml;s; <code>.rotationLast</code>, <code>.rotationStartTs</code>,
      <code>.rotationUntilTs</code> - interner Rotationszustand f&uuml;r die Fortsetzung nach Neustart</li>
  </ul>
</ul>

=end html_DE
=cut
