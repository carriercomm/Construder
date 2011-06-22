package Games::Construder::Server::Player;
use Devel::FindRef;
use common::sense;
use AnyEvent;
use Games::Construder::Server::World;
use Games::Construder::Server::UI;
use Games::Construder::Server::Objects;
use Games::Construder::Server::PatStorHandle;
use Games::Construder::Vector;
use Time::HiRes qw/time/;
use base qw/Object::Event/;
use Scalar::Util qw/weaken/;
use Compress::LZF;

=head1 NAME

Games::Construder::Server::Player - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Construder::Server::Player->new (%args)

=cut

my $PL_VIS_RAD = 3;
my $PL_MAX_INV = 24;

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->init_object_events;

   return $self
}

sub _check_file {
   my ($self) = @_;
   my $pld = $Games::Construder::Server::Resources::PLAYERDIR;
   my $file = "$pld/$self->{name}.json";
   return unless -e "$file";

   if (open my $plf, "<", $file) {
      binmode $plf, ":raw";
      my $cont = do { local $/; <$plf> };
      my $data = eval { JSON->new->relaxed->utf8->decode ($cont) };
      if ($@) {
         warn "Couldn't parse player data from file '$file': $!\n";
         return;
      }

      return $data

   } else {
      warn "Couldn't open player file $file: $!\n";
      return;
   }
}

sub _initialize_player {
   my ($self) = @_;
   my $inv = $Games::Construder::Server::RES->get_initial_inventory;
   my $data = {
      name      => $self->{name},
      happyness => 100,
      bio       => 100,
      score     => 0,
      pos       => [0, 0, 0],
      inv       => $inv,
      slots => {
         selection => [],
         selected  => 0
      },
   };

   $data
}

sub load {
   my ($self) = @_;

   my $data = $self->_check_file;
   unless (defined $data) {
      $data = $self->_initialize_player;
   }

   $self->{data} = $data;
}

sub save {
   my ($self) = @_;
   my $cont = JSON->new->pretty->utf8->encode ($self->{data});
   my $pld = $Games::Construder::Server::Resources::PLAYERDIR;
   my $file = "$pld/$self->{name}.json";

   if (open my $plf, ">", "$file~") {
      binmode $plf, ":raw";
      print $plf $cont;
      close $plf;

      if (-s "$file~" != length ($cont)) {
         warn "Couldn't write out player file completely to '$file~': $!\n";
         return;
      }

      unless (rename "$file~", "$file") {
         warn "Couldn't rename $file~ to $file: $!\n";
         return;
      }

      warn "saved player $self->{name} to $file.\n";

   } else {
      warn "Couldn't open player file $file~ for writing: $!\n";
      return;
   }
}

sub init {
   my ($self) = @_;
   $self->load;
   $self->save;
   $self->set_vis_rad;

   my $wself = $self;
   weaken $wself;
   my $tick_time = time;
   my $msg_beacon_upd = 0;
   my $save_tmr = 0;

   $self->{tick_timer} = AE::timer 0.25, 0.25, sub {
      my $cur = time;
      my $dt = $cur - $tick_time;
      $wself->player_tick ($cur - $tick_time);
      $tick_time = $cur;
      $msg_beacon_upd += $dt;
      $save_tmr += $dt;
      $self->{data}->{time} += $dt;
      if ($msg_beacon_upd > 2)
         {
            $msg_beacon_upd = 0;
            $self->check_message_beacons;

            $self->check_assignment_offers (2);
         }

      if ($save_tmr >= 30)
         {
            $save_tmr = 0;
            $self->save;
         }
   };

   $self->new_ui (bio_warning   => "Games::Construder::Server::UI::BioWarning");
   $self->new_ui (msgbox        => "Games::Construder::Server::UI::MsgBox");
   $self->new_ui (score         => "Games::Construder::Server::UI::Score");
   $self->new_ui (slots         => "Games::Construder::Server::UI::Slots");
   $self->new_ui (status        => "Games::Construder::Server::UI::Status");
   $self->new_ui (material_view => "Games::Construder::Server::UI::MaterialView");
   $self->new_ui (inventory     => "Games::Construder::Server::UI::Inventory");
   $self->new_ui (cheat         => "Games::Construder::Server::UI::Cheat");
   $self->new_ui (sector_finder => "Games::Construder::Server::UI::SectorFinder");
   $self->new_ui (navigator     => "Games::Construder::Server::UI::Navigator");
   $self->new_ui (navigation_programmer
                                => "Games::Construder::Server::UI::NavigationProgrammer");
   $self->new_ui (assignment      => "Games::Construder::Server::UI::Assignment");
   $self->new_ui (assignment_time => "Games::Construder::Server::UI::AssignmentTime");
   $self->new_ui (pattern_storage => "Games::Construder::Server::UI::PatternStorage");
   $self->new_ui (material_handbook => "Games::Construder::Server::UI::MaterialHandbook");
   $self->new_ui (notebook      => "Games::Construder::Server::UI::Notebook");
   $self->new_ui (msg_beacon    => "Games::Construder::Server::UI::MessageBeacon");
   $self->new_ui (msg_beacon_list => "Games::Construder::Server::UI::MessageBeaconList");
   $self->new_ui (teleporter    => "Games::Construder::Server::UI::Teleporter");
   $self->new_ui (color_select  => "Games::Construder::Server::UI::ColorSelector");

   $self->{inv} =
      Games::Construder::Server::PatStorHandle->new (data => $self->{data}, slot_cnt => $PL_MAX_INV);

   $self->{inv}->reg_cb (changed => sub {
      if ($wself->{uis}->{inventory}->{shown}) {
         $wself->{uis}->{inventory}->show;
      }
      warn "INVENTORY CHANGED!\n";
      $wself->{uis}->{slots}->show;
   });

   $self->update_score;
   $self->{uis}->{slots}->show;
   $self->send_visible_chunks;
   $self->teleport ();
   $self->check_assignment;
}

sub now { $_[0]->{data}->{time} }

sub push_tick_change {
   my ($self, $key, $amt) = @_;
   push @{$self->{tick_changes}}, [$key, $amt];
}

sub player_tick {
   my ($self, $dt) = @_;

   my $player_values = $Games::Construder::Server::RES->player_values ();

   while (@{$self->{tick_changes}}) {
      my ($k, $a) = @{shift @{$self->{tick_changes}}};

      if ($k eq 'happyness' || $k eq 'bio') {
         $self->{data}->{$k} += $a;

         if ($self->{data}->{$k} > 100) {
            $self->{data}->{$k} = 100;
         }

      } elsif ($k eq 'score') {
         my $happy = $Games::Construder::Server::RES->score2happyness ($a);
         $self->{data}->{happyness} += int ($happy + 0.5);

         if ($self->{data}->{happyness} < 90) {
            $a = 0;
         } elsif ($self->{data}->{happyness} > 100) {
            $self->{data}->{happyness} = 100;
         }

         if ($a) {
            $self->update_score ($a);
            $self->{data}->{score} += $a;
            $self->{data}->{score} = int $self->{data}->{score};
         }
      }  elsif ($k eq 'score_punishment') {
         $self->update_score (-$a);
         $self->{data}->{score} -= $a;
         $self->{data}->{score} = 0 if $self->{data}->{score} < 0;
      }
   }

   my $bio_rate;

   $self->{data}->{happyness} -= $dt * $player_values->{unhappy_rate};
   if ($self->{data}->{happyness} < 0) {
      $self->{data}->{happyness} = 0;
      $bio_rate = $player_values->{bio_unhappy};

   } elsif ($self->{data}->{happyness} > 0) {
      $bio_rate = $player_values->{bio_happy};
   }

   $self->{data}->{bio} -= $dt * $bio_rate;
   if ($self->{data}->{bio} <= 0) {
      $self->{data}->{bio} = 0;

      if (!$self->try_eat_something) { # danger: this maybe recurses into player_tick :)
         $self->starvation (1);
      }
   } else {
      $self->starvation (0);
   }

   my $hunger = 100 - $self->{data}->{bio};
   $self->try_eat_something ($hunger);
}

sub starvation {
   my ($self, $starves) = @_;

   my $bio_ui = $self->{uis}->{bio_warning};

   if ($starves) {
      unless ($self->{death_timer}) {
         my $cnt = 30;
         $self->{death_timer} = AE::timer 0, 1, sub {
            if ($cnt-- <= 0) {
               $self->kill_player;
               delete $self->{death_timer};

               $bio_ui->hide;
            } else {
               $bio_ui->show ($cnt);
            }
         };
      }

   } else {
      if (delete $self->{death_timer}) {
         $bio_ui->hide;
      }
   }
}

sub try_eat_something {
   my ($self, $amount) = @_;

   my $max_e = $self->{inv}->max_bio_energy_material;

   return 0 unless $max_e;

   my $item = $max_e;
   if ($amount) {
      if ($item->[1] <= $amount) {
         my ($ov) = $self->{inv}->remove ($item->[0]);
         if ($ov) {
            $self->refill_bio ($item->[1]);
            return 1;
         }
      }

   } else {
      my ($ov) = $self->{inv}->remove ($item->[0]);
      if ($ov) {
         $self->refill_bio ($item->[1]);
         return 1;
      }
   }

   return 0;
}

sub refill_bio {
   my ($self, $amount) = @_;

   $self->{data}->{bio} += $amount;
   $self->{data}->{bio} = 100
      if $self->{data}->{bio} > 100;

   if ($self->{data}->{bio} > 0) {
      $self->starvation (0); # make sure we don't starve anymore
   }
}

sub kill_player {
   my ($self) = @_;
   $self->teleport ([0, 0, 0]);
   $self->{inv}->remove ('all');
   $self->{data}->{happyness} = 100;
   $self->{data}->{bio}       = 100;
   $self->{data}->{score}    -=
      int ($self->{data}->{score} * (20 / 100)); # 20% score loss

}

sub logout {
   my ($self) = @_;
   $self->save;
   delete $self->{uis};
   delete $self->{upd_score_hl_tmout};
   delete $self->{death_timer};
   delete $self->{tick_timer};
   warn "player $self->{name} logged out\n";
   print Devel::FindRef::track $self;
}

my $world_c = 0;

sub set_vis_rad {
   my ($self, $rad) = @_;
   $self->{vis_rad} = $rad || $PL_VIS_RAD;
}

sub visible_chunks {
   my ($self, $from, $chnk) = @_;

   my $plchnk = world_pos2chnkpos ($from);
   $chnk ||= $plchnk;

   my $rad = $self->{vis_rad};

   my @c;
   for my $dx (-$rad..$rad) {
      for my $dy (-$rad..$rad) {
         for my $dz (-$rad..$rad) {
            my $cur = [$chnk->[0] + $dx, $chnk->[1] + $dy, $chnk->[2] + $dz];
            next if vlength (vsub ($cur, $plchnk)) >= $rad;
            push @c, $cur;
         }
      }
   }

   @c
}

sub update_pos {
   my ($self, $pos, $lv) = @_;

   my $opos = $self->{data}->{pos};
   $self->{data}->{pos} = $pos;
   my $olv = $self->{data}->{look_vec} || [0,0,0];
   $self->{data}->{look_vec} = vnorm ($lv);

   my $oblk = vfloor ($opos);
   my $nblk = vfloor ($pos);

   my $new_pos = vlength (vsub ($oblk, $nblk)) > 0;
   my $new_lv  = vlength (vsub ($olv, $lv)) > 0.05;
   my $dnew_lv = vlength (vsub ($olv, $lv));

   if ($new_pos || $new_lv) {
      if ($self->{uis}->{navigator}->{shown}) {
         $self->{uis}->{navigator}->show;
      }
   }

   return unless $new_pos;

   # just trigger this, if new chunks are generated or loaded they
   # will be automatically sent if visible by chunk_updated.
   world_load_at ($pos); # fixme: still blocks for now :)

   # send whats available for now
   my $last_vis = $self->{last_vis} || {};
   my $next_vis = {};
   my @chunks   = $self->visible_chunks ($pos);
   my @new_chunks;
   for (@chunks) {
      my $id = world_pos2id ($_);
      unless ($last_vis->{$id}) {
         push @new_chunks, $_;
      }
      $next_vis->{$id} = 1;
   }
   $self->{last_vis} = $next_vis;

   if (@new_chunks) {
      $self->send_client ({ cmd => "chunk_upd_start" });
      $self->send_chunk ($_) for @new_chunks;
      $self->send_client ({ cmd => "chunk_upd_done" });
   }
}

sub get_pos_normalized {
   my ($self) = @_;
   vfloor ($self->{data}->{pos})
}

sub get_pos_chnk {
   my ($self) = @_;
   world_pos2chnkpos ($self->{data}->{pos})
}

sub get_pos_sector {
   my ($self) = @_;
   world_chnkpos2secpos (world_pos2chnkpos ($self->{data}->{pos}))
}

sub chunk_updated {
   my ($self, $chnk) = @_;

   my $plchnk = world_pos2chnkpos ($self->{data}->{pos});
   my $divvec = vsub ($chnk, $plchnk);
   return if vlength ($divvec) >= $self->{vis_rad};

   $self->send_chunk ($chnk);
}

sub send_visible_chunks {
   my ($self) = @_;

   $self->send_client ({ cmd => "chunk_upd_start" });

   my @chnks = $self->visible_chunks ($self->{data}->{pos});
   $self->send_chunk ($_) for @chnks;

   warn "done sending " . scalar (@chnks) . " visible chunks.\n";
   $self->send_client ({ cmd => "chunk_upd_done" });
}

sub send_chunk {
   my ($self, $chnk) = @_;

   # only send chunk when allcoated, in all other cases the chunk will
   # be sent by the chunk_changed-callback by the server (when it checks
   # whether any player might be interested in that chunk).
   my $data = Games::Construder::World::get_chunk_data (@$chnk);
   return unless defined $data;
   $self->send_client ({ cmd => "chunk", pos => $chnk }, compress ($data));
}

sub msg {
   my ($self, $error, $msg) = @_;
   $self->{uis}->{msgbox}->show ($error, $msg);
}

sub update_score {
   my ($self, $hl) = @_;
   $self->{uis}->{score}->show ($hl);
}

sub query {
   my ($self, $pos) = @_;
   return unless @$pos;

   world_mutate_at ($pos, sub {
      my ($data) = @_;
      if ($data->[0]) {
         $self->{uis}->{material_view}->show ($data->[0]);
      }
      return 0;
   });
}

sub interact {
   my ($self, $pos) = @_;

   world_at ($pos, sub {
      my ($pos, $cell) = @_;
      print "interact position [@$pos]: @$cell\n";
      Games::Construder::Server::Objects::interact ($self, $pos, $cell->[0], $cell->[5]);
   });
}

sub highlight {
   my ($self, $pos, $time, $color) = @_;
   $self->send_client ({
      cmd   => "highlight",
      pos   => $pos,
      color => $color,
      fade  => -$time
   });
}

sub debug_at {
   my ($self, $pos) = @_;
   $self->send_client ({
      cmd => "model_highlight",
      pos => $pos,
      model => [
         map {
            my $x = $_;
            map {
               my $y = $_;
               map { [[$x, $y, $_], [1, 0, rand (100) / 100, 0.2]] } 0..10
            } 0..10
         } 0..10
      ],
      id => "debug"
   });
   world_mutate_at ($pos, sub {
      my ($data) = @_;
      print "position [@$pos]: @$data\n";
      if ($data->[0] == 1) {
         $data->[0] = 0;
         return 1;
      }
      return 0;
   });
}

sub do_materialize {
   my ($self, $pos, $time, $energy, $score, $type, $ent) = @_;

   my $id = world_pos2id ($pos);

   $self->highlight ($pos, $time, [0, 1, 0]);

   $self->push_tick_change (bio => -$energy);

   $self->{materializings}->{$id} = 1;
   my $tmr;
   $tmr = AE::timer $time, 0, sub {
      world_mutate_at ($pos, sub {
         my ($data) = @_;
         undef $tmr;

         $data->[0] = $type;
         $data->[5] = $ent if $ent;
         $data->[3] = $self->{colorifyer} & 0x0f;
         delete $self->{materializings}->{$id};
         $self->push_tick_change (score => $score);
         return 1;
      });
   };
}

sub get_selected_slot {
   my ($self) = @_;
   my $id = $self->{data}->{slots}->{selection}->[$self->{data}->{slots}->{selected}];
   my ($type, $entid) = split /:/, $id, 2;
   if ($entid ne '') {
      return ($type, $id)
   } else {
      return ($id, $id);
   }
}

sub start_materialize {
   my ($self, $pos) = @_;

   my $id = world_pos2id ($pos);
   if ($self->{materializings}->{$id}) {
      return;
   }

   my ($invid)
      = $self->{data}->{slots}->{selection}->[$self->{data}->{slots}->{selected}];
   my ($type, $invid) = $self->{inv}->split_invid ($invid);

   world_mutate_at ($pos, sub {
      my ($data) = @_;

      return 0 unless $data->[0] == 0;

      my ($cnt, $ent) = $self->{inv}->remove ($invid);

      return 0 unless $cnt;

      my $obj = $Games::Construder::Server::RES->get_object_by_type ($type);
      my ($time, $energy, $score) =
         $Games::Construder::Server::RES->get_type_materialize_values ($type);
      unless ($self->{data}->{bio} >= $energy) {
         $self->msg (1, "You don't have enough energy to materialize the $obj->{name}!");
         return;
      }

      $data->[0] = 1;
      $self->do_materialize ($pos, $time, $energy, $score, $type, $ent);
      return 1;
   }, no_light => 1);
}

sub do_dematerialize {
   my ($self, $pos, $time, $energy, $type, $ent) = @_;

   my $id = world_pos2id ($pos);
   $self->highlight ($pos, $time, [1, 0, 0]);

   $self->push_tick_change (bio => -$energy);

   $self->{dematerializings}->{$id} = 1;
   my $tmr;
   $tmr = AE::timer $time, 0, sub {
      undef $tmr;

      world_mutate_at ($pos, sub {
         my ($data) = @_;

         if ($self->{inv}->add ($type, $ent || 1)) {
            $data->[0] = 0;
            $data->[3] &= 0xF0; # clear color :)
            if ($ent) {
               Games::Construder::Server::Objects::destroy ($ent);
            }
         } else {
            $data->[0] = $type;
            $data->[5] = $ent;
            $data->[3] &= 0xF0; # clear color :) FIXME: should set previous
         }
         delete $self->{dematerializings}->{$id};
         return 1;
      });
   };
}

sub start_dematerialize {
   my ($self, $pos) = @_;

   my $id = world_pos2id ($pos);
   if ($self->{dematerializings}->{$id}) {
      return;
   }

   world_mutate_at ($pos, sub {
      my ($data) = @_;
      my $type = $data->[0];
      my $obj = $Games::Construder::Server::RES->get_object_by_type ($type);
      if ($obj->{untransformable}) {
         return;
      }
      warn "DEMAT $type\n";

      unless ($self->{inv}->has_space_for ($type)) {
         $self->msg (1, "Inventory full, no space for $obj->{name} available!");
         return;
      }

      my ($time, $energy) =
         $Games::Construder::Server::RES->get_type_dematerialize_values ($type);
      unless ($obj->{bio_energy} || $self->{data}->{bio} >= $energy) {
         $self->msg (1, "You don't have enough energy to dematerialize the $obj->{name}!");
         return;
      }

      $data->[0] = 1; # materialization!
      my $ent = $data->[5];
      $data->[5] = undef;
      $self->do_dematerialize ($pos, $time, $energy, $type, $ent);

      return 1;
   }, no_light => 1, need_entity => 1);
}

sub _map_value_to_material {
   my ($map, $val) = @_;
   for (@$map) {
      my ($a, $b, $t) = @$_;
      return $t if $val >= $a && $val < $b;
   }
   undef
}

sub check_message_beacons {
   my ($self) = @_;

   my $msgboxes =
      Games::Construder::World::get_types_in_cube (
         @{vsubd ($self->get_pos_normalized, 15, 15, 15)}, 30, 34);

   my $cur_beacons = {};
   while (@$msgboxes) {
      my ($pos, $type) = (
         [shift @$msgboxes, shift @$msgboxes, shift @$msgboxes], shift @$msgboxes
      );
      my $e = world_entity_at ($pos);
      my $id = world_pos2id ($pos);
      $cur_beacons->{$id} = $self->{data}->{beacons}->{$id} = [
         $pos, $e->{msg}, $self->now
      ];
   }

   my $now = $self->now;

   for (keys %{$self->{data}->{beacons}}) {
      if (($now - $self->{data}->{beacons}->{$_}->[2]) > 30 * 60) {
         delete $self->{data}->{beacons}->{$_};
      }
   }

   $self->{uis}->{msg_beacon_list}->show ($cur_beacons);
}

our @OFFER_TIMES = (
   5  * 60,
   7  * 60,
   10 * 60,
   15 * 60,
   20 * 60,
);

our @DIFF_PUNSH_FACT = (
   0.05,
   0.1,
   0.2,
   0.5,
   0.7,
   0.9
);

sub check_assignment_offers {
   my ($self, $dt) = @_;
;
   for (my $d = 0; $d < 5; $d++) {
      my $offer = $self->{data}->{offers}->[$d];
      if ($offer) {
         $offer->{offer_time} -= $dt;
         if ($offer->{offer_time} <= 0) {
            undef $offer;
         }
      }

      unless ($offer) {
         my ($desc, $size, $material_map, $distance, $time, $score) =
            $Games::Construder::Server::RES->get_assignment_for_score (
               $self->{data}->{score}, $d * 2);
         $offer = {
            diff         => $d,
            cmds         => $desc,
            size         => $size,
            material_map => $material_map,
            distance     => $distance,
            time         => $time,
            score        => $score,
            offer_time   => $OFFER_TIMES[$d],
            punishment   => int ($DIFF_PUNSH_FACT[$d] * $score),
         };
      }

      $self->{data}->{offers}->[$d] = $offer;
   }

   if ($self->{uis}->{assignment}->{shown}) {
      $self->{uis}->{assignment}->show;
   }
}

sub take_assignment {
   my ($self, $nr) = @_;

   my $offer = $self->{data}->{offers}->[$nr];
   $self->{data}->{offers}->[$nr] = undef;

   #my ($desc, $size, $material_map, $distance, $time, $score) =
   #   $Games::Construder::Server::RES->get_assignment_for_score ($self->{data}->{score});

   #print "ASSIGNMENT BASE VALUES: " . JSON->new->pretty->encode ([
   #   $desc, $size, $material_map, $distance, $time, $score
   #]) . "\n";

   # random direction:
   my $x = (rand () * 2) - 1;
   my $y = (rand () * 2) - 1;
   my $z = (rand () * 2) - 1;

   my $vec  = vsmul (vnorm ([$x, $y, $z]), $offer->{distance});
   my $wpos = vfloor (vadd ($vec, $self->get_pos_normalized));

   warn "assignment at @$vec => @$wpos\n";

   my $size = $offer->{size};
   Games::Construder::VolDraw::alloc ($size);

   Games::Construder::VolDraw::draw_commands (
     $offer->{cmds},
     { size => $size, seed => $offer->{score}, param => 1 }
   );

   my $cube = Games::Construder::VolDraw::to_perl ();
   shift @$cube;

   my $material_map = $offer->{material_map};
   my $materials = {};
   my $positions = {};

   for (my $x = 0; $x < $size; $x++) {
      for (my $y = 0; $y < $size; $y++) {
         for (my $z = 0; $z < $size; $z++) {
            my $val = shift @$cube;
            my $type = _map_value_to_material ($material_map, $val);
            next unless defined $type;
            my $model = ($materials->{$type} ||= []);

            my $pos = [$x, $y, $z];
            push @$model, [$pos, [1, 0, 1, 0.2]];

            my $id = join ",", @{vadd ($pos, $wpos)};
            $positions->{$id} = $type;
         }
      }
   }

   my $cal = $self->{data}->{assignment} = $offer;
   $cal->{pos}        = $wpos;
   $cal->{materials}  = [sort keys %$materials];
   $cal->{sel_mat}    = $cal->{materials}->[0];
   print "ASSIGNMENT : " . JSON->new->pretty->encode ($cal) . "\n";
   $cal->{pos_types}  = $positions;
   $cal->{mat_models} = $materials;

   $self->{uis}->{assignment}->show;

   delete $self->{assign_ment_hl};
   $self->check_assignment;
}

sub check_assignment_positions {
   my ($self) = @_;

   my $t      = time;
   my $assign = $self->{data}->{assignment};
   my $lpos   = { %{$assign->{pos_types}} };
   my $typ    =
      Games::Construder::World::get_types_in_cube (@{$assign->{pos}}, $assign->{size});

   #d#printf "CHECK TIME 1 %f\n", time - $t;

   for (my $x = 0; $x < $assign->{size}; $x++) {
      for (my $y = 0; $y < $assign->{size}; $y++) {
         for (my $z = 0; $z < $assign->{size}; $z++) {
            my $t = shift @$typ;
            my $pid = join (",", @{vaddd ($assign->{pos}, $x, $y, $z)});

            if ($assign->{pos_types}->{$pid}) {
               if ($assign->{pos_types}->{$pid} == $t) {
                  delete $lpos->{$pid};
               }
            }
         }
      }
   }

   my %tleft;
   for (keys %$lpos) {
      $tleft{$lpos->{$_}}++;
   }
   $assign->{left} = \%tleft;

   #d#printf "CHECK TIME 2 %f\n", time - $t;

   $self->update_assignment_highlight;

   unless (grep { $_ != 0 } values %tleft) {
      $self->finished_assignmenet;
   }
}

sub assignment_select_next {
   my ($self) = @_;
   my $assign = $self->{data}->{assignment};
   my @left = grep {
      $assign->{left}->{$_} > 0
   } keys %{$assign->{left}};

   push @left, @left;
   for (my $i = 0; $i < (@left / 2); $i++) {
      if ($left[$i] == $assign->{sel_mat}) {
         $assign->{sel_mat} = $left[$i + 1];
         last;
      }
   }

   delete $self->{assign_ment_hl};
   $self->update_assignment_highlight;
   $self->{uis}->{assignment_time}->show;
}

sub update_assignment_highlight {
   my ($self) = @_;

   my $assign = $self->{data}->{assignment};
   my $selected = $assign->{sel_mat};
   if ($assign->{left}->{$selected} <= 0) {
      ($assign->{sel_mat}) = grep {
         $assign->{left}->{$_} > 0
      } keys %{$assign->{left}};
      delete $self->{assign_ment_hl};
   }

   unless ($self->{assign_ment_hl}) {
      $self->{assign_ment_hl} = 1;
      my $mat = $assign->{sel_mat};

      $self->send_client ({
         cmd   => "model_highlight",
         pos   => $assign->{pos},
         model => $assign->{mat_models}->{$mat},
         id    => "assignment",
      });
   }
}

sub check_assignment {
   my ($self) = @_;

   my $assign = $self->{data}->{assignment};
   unless ($assign) {
      $self->{uis}->{assignment_time}->hide;
      $self->send_client ({
         cmd => "model_highlight",
         id => "assignment"
      });
      return;
   }

   $self->check_assignment_positions;

   $self->{uis}->{assignment_time}->show;
   my $wself = $self;
   weaken $wself;
   $self->{assign_timer} = AE::timer 1, 1, sub {
      $wself->check_assignment_positions;

      $wself->{data}->{assignment}->{time} -= 1;
      $wself->{uis}->{assignment_time}->show;
      if ($wself->{data}->{assignment}->{time} <= 0) {
         $wself->cancel_assignment;
      }
   };
}

sub finished_assignmenet {
   my ($self) = @_;
   $self->push_tick_change (score => $self->{data}->{assignment}->{score});
   $self->{data}->{assignment} = undef;
   delete $self->{assign_timer};
   $self->check_assignment;
}

sub cancel_assignment {
   my ($self) = @_;
   my $ass = $self->{data}->{assignment};
   $self->push_tick_change (score_punishment => $ass->{punishment});
   $self->{data}->{assignment} = undef;
   delete $self->{assign_timer};
   $self->check_assignment;
}

sub send_client : event_cb {
   my ($self, $hdr, $body) = @_;
}

sub teleport {
   my ($self, $pos) = @_;

   $pos ||= $self->{data}->{pos};
   world_load_at ($pos, sub {
      my $new_pos = world_find_free_spot ($pos, 1);
      unless ($new_pos) {
         $new_pos = world_find_free_spot ($pos, 0); # without floor on second try
      }
      $new_pos = vaddd ($new_pos, 0.5, 0.5, 0.5);
      $self->send_client ({ cmd => "place_player", pos => $new_pos });
   });
}

sub new_ui {
   my ($self, $id, $class, %arg) = @_;
   my $o = $class->new (ui_name => $id, pl => $self, %arg);
   $self->{uis}->{$id} = $o;
}

sub delete_ui {
   my ($self, $id) = @_;
   delete $self->{uis}->{$id};
}

sub display_ui {
   my ($self, $id, $dest) = @_;

   my $o = $self->{uis}->{$id};

   unless ($dest) {
      $self->send_client ({ cmd => deactivate_ui => ui => $id });
      delete $o->{shown};
      return;
   }

   $self->send_client ({ cmd => activate_ui => ui => $id, desc => $dest });
   $o->{shown} = 1;
}

sub ui_res : event_cb {
   my ($self, $ui, $cmd, $arg, $pos) = @_;
   warn "ui response $ui: $cmd ($arg) (@$pos)\n";

   if (my $o = $self->{uis}->{$ui}) {
      $o->react ($cmd, $arg, $pos);

      delete $o->{shown}
         if $cmd eq 'cancel';
   }
}

sub DESTROY {
   my ($self) = @_;
   warn "player $self->{name} [$self] destroyed!\n";
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
