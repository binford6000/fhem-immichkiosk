# $Id$
##############################################################################
# 98_ImmichKiosk.pm
# Controls immich-kiosk (https://github.com/damongolding/immich-kiosk) from FHEM
##############################################################################
package main;
use strict;
use warnings;
use HttpUtils;
use JSON::PP ();
use Encode qw(encode decode);
my $IK_VERSION = "0.3.0";
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
  $hash->{IMMICH_URL} = $a[2] =~ s{/+$}{}r;
  $hash->{KIOSK_URL}  = $a[3];
  $hash->{VERSION}    = $IK_VERSION;
  $hash->{NOTIFYDEV}  = "global";
  # new device (not loaded from fhem.cfg): put it into its own room
  if ($init_done) {
    CommandAttr(undef, "$a[0] room ImmichKiosk") if (!AttrVal($a[0], "room", undef));
    CommandAttr(undef, "$a[0] webCmd $IK_WEBCMD") if (!AttrVal($a[0], "webCmd", undef));
    CommandAttr(undef, "$a[0] cmdIcon $IK_CMDICON") if (!AttrVal($a[0], "cmdIcon", undef));
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
  return if (IsDisabled($hash->{NAME}));
  ImmichKiosk_StartTimers($hash);
  # continue a running rotation after restart
  ImmichKiosk_Reread($hash, sub { ImmichKiosk_Rotate($hash, "resume") });
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
  if ($cmd eq "album") {
    return "usage: set $name album <name>" if (!@args);
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
    return "no albums available" if (!@l);
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
    ImmichKiosk_Reread($hash);
    return;
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
  if ($cmd eq "albums") {
    ImmichKiosk_LoadAlbums($hash);
    my $a = $hash->{helper}{albums} // {};
    return "no albums loaded" if (!%{$a});
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
  }
  elsif ($attr =~ /^(albumRefreshInterval|progressInterval|disable)$/ && $init_done) {
    RemoveInternalTimer($hash, "ImmichKiosk_StartTimers");
    InternalTimer(gettimeofday() + 1, "ImmichKiosk_StartTimers", $hash);
    if ($attr eq "disable" && $cmd eq "set" && $val) {
      RemoveInternalTimer($hash, "ImmichKiosk_RotateTimer");
      readingsSingleUpdate($hash, "state", "disabled", 1);
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
  if (!$key) {
    readingsSingleUpdate($hash, "lastError", "apiKey missing", 1);
    return;
  }
  HttpUtils_NonblockingGet({
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
    my $msg = $err || "HTTP $code";
    Log3($name, 2, "$name: album reread failed: $msg");
    readingsSingleUpdate($hash, "lastError", "album reread: $msg", 1);
    return;
  }
  my $list = eval { JSON::PP::decode_json($data) };
  if (ref($list) ne "ARRAY") {
    Log3($name, 2, "$name: album reread: invalid JSON from Immich");
    readingsSingleUpdate($hash, "lastError", "album reread: invalid response", 1);
    return;
  }
  $IK_RAW{$name} = $list;
  ImmichKiosk_BuildAlbums($hash, {});
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "lastReread", TimeNow());
  readingsBulkUpdate($hash, "state", ReadingsVal($name, "album", "ready"));
  readingsEndUpdate($hash, 1);
  $param->{next}->() if (ref($param->{next}) eq "CODE");
  return;
}
sub ImmichKiosk_BuildAlbums {
  my ($hash, $ov) = @_;
  my $name = $hash->{NAME};
  my $av   = sub { exists($ov->{$_[0]}) ? $ov->{$_[0]} : AttrVal($name, $_[0], $_[1]) };
  my %excl = map { $_ => 1 } split(/[\s,]+/, $av->("albumExclude", ""));
  my %albums;
  for my $al (@{$IK_RAW{$name} // []}) {
    # skip empty albums
    next if (!$al->{assetCount} || !$al->{id});
    my $n = ImmichKiosk_CleanName($al->{albumName});
    next if ($n eq "" || $excl{$n});
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
    $albums{$vname} = { ids => \@ids, count => $count, label => $vname, virtual => 1 } if (@ids);
  }
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
  my ($hash, $album, $fromRotation) = @_;
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
  readingsBulkUpdate($hash, "albumPictures", $e->{count} // "-");
  readingsBulkUpdate($hash, "url", ImmichKiosk_BuildUrl($hash, $e->{ids}, 0));
  readingsBulkUpdate($hash, "state", $album);
  readingsEndUpdate($hash, 1);
  ImmichKiosk_SendUrl($hash, $e->{ids});
  Log3($name, 3, "$name: loading album $album");
  return;
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
  ImmichKiosk_Fully($hash, "setStringSetting", { key => "startURL", value => $url },
    sub { ImmichKiosk_Fully($hash, "loadStartURL", {}) });
  return;
}
##############################################################################
# Rotation: start | stop | next | prev | resume
##############################################################################
sub ImmichKiosk_Rotate {
  my ($hash, $cmd) = @_;
  my $name = $hash->{NAME};
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
    Log3($name, 2, "$name: rotation - no albums available");
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
  my $e   = $hash->{helper}{albums}{$n};
  my $layout = AttrVal($name, "layout", "single");
  my $ctx = { album => $n, keep => $keep, gen => $gen, count => $e->{count}, layout => $layout,
              land => 0, port => 0, square => 0, page => 1 };
  # single: every asset is one slide, no EXIF query needed
  return ImmichKiosk_RotateApply($hash, $ctx, $e->{count}) if ($layout eq "single");
  ImmichKiosk_SlidesFetch($hash, $ctx, $e->{ids}[0]);
  return;
}
sub ImmichKiosk_SlidesFetch {
  my ($hash, $ctx, $id) = @_;
  my $key  = ImmichKiosk_GetSecret($hash, "apiKey") // "";
  my $body = JSON::PP->new->encode({ albumIds => [$id], type => "IMAGE", withExif => JSON::PP::true(),
                                     size => 1000, page => 0 + $ctx->{page} });
  HttpUtils_NonblockingGet({
    url      => "$hash->{IMMICH_URL}/api/search/metadata",
    method   => "POST",
    data     => $body,
    timeout  => 15,
    header   => "x-api-key: $key\r\nContent-Type: application/json\r\nAccept: application/json",
    hash     => $hash,
    ctx      => $ctx,
    albumId  => $id,
    callback => \&ImmichKiosk_SlidesParse,
  });
  return;
}
sub ImmichKiosk_SlidesParse {
  my ($param, $err, $data) = @_;
  my $hash  = $param->{hash};
  my $ctx   = $param->{ctx};
  my $name  = $hash->{NAME};
  my $res   = (!$err && ($param->{code} // 0) == 200) ? eval { JSON::PP::decode_json($data) } : undef;
  my $items = (ref($res) eq "HASH" && ref($res->{assets}) eq "HASH") ? $res->{assets}{items} : undef;
  if (ref($items) ne "ARRAY") {
    Log3($name, 2, "$name: image formats for $ctx->{album} not available ("
                 . ($err || "HTTP " . ($param->{code} // "?")) . "), using asset count");
    return ImmichKiosk_RotateApply($hash, $ctx, $ctx->{count});
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
    return ImmichKiosk_SlidesFetch($hash, $ctx, $param->{albumId});
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
  Log3($name, 4, "$name: $ctx->{album}: landscape $l, portrait $p, square/unknown $q, layout $ctx->{layout} -> $slides slides");
  return ImmichKiosk_RotateApply($hash, $ctx, $slides);
}
sub ImmichKiosk_RotateApply {
  my ($hash, $ctx, $slides) = @_;
  my $name = $hash->{NAME};
  my $n    = $ctx->{album};
  # stopped or superseded in the meantime
  return if ($ctx->{gen} != $hash->{helper}{rotGen} || ReadingsVal($name, "rotation", "off") ne "on");
  $slides = 1 if (!$slides || $slides < 1);
  my $secs = $slides * (AttrVal($name, "imageDuration", 60) + AttrVal($name, "imageBuffer", 0));
  my $max  = AttrVal($name, "rotationMax", 0);
  $secs = $max if ($max && $secs > $max);
  my $ts  = int(time() + $secs);
  # duration as HH:MM (hours may exceed 24)
  my $dur = sprintf("%02d:%02d", int($secs / 3600), int($secs % 3600 / 60));
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, ".rotationLast", $n);
  readingsBulkUpdate($hash, ".rotationStartTs", int(time()));
  readingsBulkUpdate($hash, ".rotationUntilTs", $ts);
  readingsBulkUpdate($hash, "rotationAlbum", $n);
  readingsBulkUpdate($hash, "rotationSlides", $slides);
  readingsBulkUpdate($hash, "rotationUntil", substr(FmtTime($ts), 0, 5));
  readingsBulkUpdate($hash, "rotationDuration", $dur);
  readingsBulkUpdate($hash, "rotationProgress", 0);
  # album kept: refresh picture count only
  readingsBulkUpdate($hash, "albumPictures", $ctx->{count} // "-") if ($ctx->{keep});
  readingsEndUpdate($hash, 1);
  ImmichKiosk_RotateAt($hash, $ts);
  ImmichKiosk_SelectAlbum($hash, $n, 1) if (!$ctx->{keep});
  Log3($name, 3, "$name: rotation - $n ($slides slides, $dur) until " . FmtDateTime($ts) . ($ctx->{keep} ? " (current album)" : ""));
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
  my $q  = "cmd=$cmd&type=json&password=" . ImmichKiosk_UrlEnc($pw);
  $q .= "&$_=" . ImmichKiosk_UrlEnc($args->{$_}) for (sort keys %{$args});
  HttpUtils_NonblockingGet({
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
    Log3($name, 2, "$name: Fully $cmd failed: " . ($err || "HTTP $code"));
    readingsSingleUpdate($hash, "lastError", "Fully $cmd: " . ($err || "HTTP $code"), 1);
    return;
  }
  my $res = eval { JSON::PP::decode_json($data) };
  if (ref($res) eq "HASH" && ($res->{status} // "") =~ /error/i) {
    Log3($name, 2, "$name: Fully $cmd: " . ($res->{statustext} // "error"));
    readingsSingleUpdate($hash, "lastError", "Fully $cmd: " . ($res->{statustext} // "error"), 1);
    return;
  }
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
<h3>ImmichKiosk</h3>
<ul>
  Controls an <a href="https://github.com/damongolding/immich-kiosk">immich-kiosk</a> slideshow.
  Albums are read from the Immich API; the selected album is passed to immich-kiosk as URL parameter,
  so the kiosk configuration file is never modified. Optionally the URL is sent to a
  Fully Kiosk Browser via its REST API.<br><br>
  <a id="ImmichKiosk-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ImmichKiosk &lt;immich-url&gt; &lt;kiosk-url&gt;</code><br>
    Example: <code>define kiosk ImmichKiosk http://immich.lan:2283 http://kiosk.lan:3000</code><br>
    A new device gets room ImmichKiosk, cmdIcon for the image commands and webCmd album (extended to
    album:prevImage:nextImage:addToFavorites once fullyUrl is set; a changed webCmd is never touched). Afterwards set the Immich API key:
    <code>set kiosk apiKey &lt;key&gt;</code>
  </ul><br>
  <a id="ImmichKiosk-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="ImmichKiosk-set-album"></a><code>album &lt;name&gt;</code><br>
      Selects an album or virtual album. Stops a running rotation.</li>
    <li><a id="ImmichKiosk-set-nextAlbum"></a><code>nextAlbum</code>, <code>prevAlbum</code><br>
      Without rotation: steps through the album list. With rotation: steps within the rotation.</li>
    <li><a id="ImmichKiosk-set-rotation"></a><code>rotation on|off</code><br>
      Automatic album rotation over all real albums (no virtual albums, no rotationExclude).
      <code>on</code> keeps the current album if it is part of the rotation.
      Display time per album: slides &times; (imageDuration + imageBuffer), limited by rotationMax.</li>
    <li><a id="ImmichKiosk-set-reread"></a><code>reread</code><br>
      Reloads the album list from Immich.</li>
    <li><a id="ImmichKiosk-set-apiKey"></a><code>apiKey &lt;key&gt;</code>,
      <code>kioskPassword &lt;pw&gt;</code>, <code>fullyPassword &lt;pw&gt;</code><br>
      Stored in the FHEM KeyValueStore. Without argument the value is deleted.</li>
    <li><a id="ImmichKiosk-set-nextImage"></a><code>nextImage</code>, <code>prevImage</code>,
      <code>addToFavorites</code>, <code>removeFromFavorites</code><br>
      Only with attribute fullyUrl: clicks the corresponding kiosk control via Fully JavaScript injection.
      addToFavorites / removeFromFavorites use the like button of the kiosk more-info overlay.</li>
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
      Default for the rotation calculation: 60.</li>
    <li><a id="ImmichKiosk-attr-imageBuffer"></a><code>imageBuffer &lt;seconds&gt;</code><br>
      Additional time per slide for transitions and loading. Default: 0.</li>
    <li><a id="ImmichKiosk-attr-layout"></a><code>layout single|portrait|landscape|splitview|splitview-landscape</code><br>
      Kiosk layout. Passed as URL parameter layout and used to calculate the number of slides per album
      (rotationSlides, rotationDuration, rotationUntil). Image orientation is determined via EXIF from Immich:
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
      If set, the kiosk URL is stored as Fully start URL and loaded.</li>
  </ul><br>
  <a id="ImmichKiosk-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code> - current album; ready before the first selection, disabled if disabled</li>
    <li><code>lastError</code> - last error (Immich, Fully, missing apiKey)</li>
    <li><code>album</code> - selected album</li>
    <li><code>albumId</code> - Immich album ID(s) or kiosk keyword of the selected album</li>
    <li><code>albumPictures</code> - number of assets of the selected album (- for kiosk keywords)</li>
    <li><code>albumList</code> - all selectable albums in list order</li>
    <li><code>albumCount</code> - number of selectable albums</li>
    <li><code>url</code> - kiosk URL of the selected album, without password</li>
    <li><code>lastReread</code> - time of the last successful album reread</li>
    <li><code>lastCommand</code> - last command sent to Fully (nextImage, prevImage, addToFavorites, removeFromFavorites)</li>
    <li><code>rotation</code> - on | off</li>
    <li><code>rotationAlbum</code> - album currently shown by the rotation</li>
    <li><code>rotationSlides</code> - number of slides of the rotation album</li>
    <li><code>rotationUntil</code> - time (HH:MM) of the next album change, - if off</li>
    <li><code>rotationDuration</code> - display time of the rotation album (HH:MM), - if off</li>
    <li><code>rotationProgress</code> - progress of the rotation album in percent (0-100)</li>
    <li>hidden: <code>.albumData</code> - JSON with all albums incl. original Immich names (label),
      e.g. for menus; <code>.rotationLast</code>, <code>.rotationStartTs</code>,
      <code>.rotationUntilTs</code> - internal rotation state, used to resume after restart</li>
  </ul>
</ul>

=end html
=begin html_DE

<a id="ImmichKiosk"></a>
<h3>ImmichKiosk</h3>
<ul>
  Steuert eine <a href="https://github.com/damongolding/immich-kiosk">immich-kiosk</a>-Diashow.
  Die Alben werden &uuml;ber die Immich-API gelesen; das gew&auml;hlte Album wird immich-kiosk als URL-Parameter
  &uuml;bergeben, die Konfigurationsdatei des Kiosk wird nie ver&auml;ndert. Optional wird die URL per REST-API
  an einen Fully Kiosk Browser gesendet.<br><br>
  <a id="ImmichKiosk-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ImmichKiosk &lt;immich-url&gt; &lt;kiosk-url&gt;</code><br>
    Beispiel: <code>define kiosk ImmichKiosk http://immich.lan:2283 http://kiosk.lan:3000</code><br>
    Ein neues Ger&auml;t bekommt room ImmichKiosk, cmdIcon f&uuml;r die Bildbefehle und webCmd album (erweitert auf
    album:prevImage:nextImage:addToFavorites, sobald fullyUrl gesetzt wird; ein ge&auml;ndertes webCmd bleibt unber&uuml;hrt). Danach den Immich-API-Key setzen:
    <code>set kiosk apiKey &lt;key&gt;</code>
  </ul><br>
  <a id="ImmichKiosk-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="ImmichKiosk-set-album"></a><code>album &lt;name&gt;</code><br>
      W&auml;hlt ein Album oder virtuelles Album. Stoppt eine laufende Rotation.</li>
    <li><a id="ImmichKiosk-set-nextAlbum"></a><code>nextAlbum</code>, <code>prevAlbum</code><br>
      Ohne Rotation: bl&auml;ttert durch die Albumliste. Mit Rotation: bl&auml;ttert innerhalb der Rotation.</li>
    <li><a id="ImmichKiosk-set-rotation"></a><code>rotation on|off</code><br>
      Automatische Album-Rotation &uuml;ber alle echten Alben (ohne virtuelle Alben und rotationExclude).
      <code>on</code> beh&auml;lt das aktuelle Album, wenn es Teil der Rotation ist.
      Anzeigedauer je Album: Slides &times; (imageDuration + imageBuffer), begrenzt durch rotationMax.</li>
    <li><a id="ImmichKiosk-set-reread"></a><code>reread</code><br>
      L&auml;dt die Albumliste neu aus Immich.</li>
    <li><a id="ImmichKiosk-set-apiKey"></a><code>apiKey &lt;key&gt;</code>,
      <code>kioskPassword &lt;pw&gt;</code>, <code>fullyPassword &lt;pw&gt;</code><br>
      Werden im FHEM-KeyValueStore gespeichert. Ohne Argument wird der Wert gel&ouml;scht.</li>
    <li><a id="ImmichKiosk-set-nextImage"></a><code>nextImage</code>, <code>prevImage</code>,
      <code>addToFavorites</code>, <code>removeFromFavorites</code><br>
      Nur mit Attribut fullyUrl: klickt das jeweilige Bedienelement des Kiosk per Fully-JavaScript-Injection.
      addToFavorites / removeFromFavorites nutzen den Like-Button im More-Info-Overlay des Kiosk.</li>
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
      Standard f&uuml;r die Rotationsberechnung: 60.</li>
    <li><a id="ImmichKiosk-attr-imageBuffer"></a><code>imageBuffer &lt;Sekunden&gt;</code><br>
      Zuschlag pro Slide f&uuml;r &Uuml;bergang und Ladezeit. Standard: 0.</li>
    <li><a id="ImmichKiosk-attr-layout"></a><code>layout single|portrait|landscape|splitview|splitview-landscape</code><br>
      Kiosk-Layout. Wird als URL-Parameter layout &uuml;bergeben und f&uuml;r die Berechnung der Slides je Album
      genutzt (rotationSlides, rotationDuration, rotationUntil). Die Bildausrichtung wird per EXIF aus Immich ermittelt:
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
      Wenn gesetzt, wird die Kiosk-URL als Fully-Start-URL gespeichert und geladen.</li>
  </ul><br>
  <a id="ImmichKiosk-readings"></a>
  <b>Readings</b>
  <ul>
    <li><code>state</code> - aktuelles Album; ready vor der ersten Auswahl, disabled wenn deaktiviert</li>
    <li><code>lastError</code> - letzter Fehler (Immich, Fully, fehlender apiKey)</li>
    <li><code>album</code> - gew&auml;hltes Album</li>
    <li><code>albumId</code> - Immich-Album-ID(s) oder Kiosk-Schl&uuml;sselwort des gew&auml;hlten Albums</li>
    <li><code>albumPictures</code> - Bildanzahl des gew&auml;hlten Albums (- bei Kiosk-Schl&uuml;sselw&ouml;rtern)</li>
    <li><code>albumList</code> - alle w&auml;hlbaren Alben in Listenreihenfolge</li>
    <li><code>albumCount</code> - Anzahl der w&auml;hlbaren Alben</li>
    <li><code>url</code> - Kiosk-URL des gew&auml;hlten Albums, ohne Passwort</li>
    <li><code>lastReread</code> - Zeitpunkt des letzten erfolgreichen Einlesens</li>
    <li><code>lastCommand</code> - letzter an Fully gesendeter Befehl (nextImage, prevImage, addToFavorites, removeFromFavorites)</li>
    <li><code>rotation</code> - on | off</li>
    <li><code>rotationAlbum</code> - von der Rotation aktuell gezeigtes Album</li>
    <li><code>rotationSlides</code> - Anzahl Slides des Rotationsalbums</li>
    <li><code>rotationUntil</code> - Uhrzeit (HH:MM) des n&auml;chsten Albumwechsels, - wenn aus</li>
    <li><code>rotationDuration</code> - Anzeigedauer des Rotationsalbums (HH:MM), - wenn aus</li>
    <li><code>rotationProgress</code> - Fortschritt des Rotationsalbums in Prozent (0-100)</li>
    <li>versteckt: <code>.albumData</code> - JSON mit allen Alben inkl. Original-Immich-Namen (label),
      z.B. f&uuml;r Men&uuml;s; <code>.rotationLast</code>, <code>.rotationStartTs</code>,
      <code>.rotationUntilTs</code> - interner Rotationszustand f&uuml;r die Fortsetzung nach Neustart</li>
  </ul>
</ul>

=end html_DE
=cut
