package Scot::Controller::File;

=head1 Name

Scot::Controller::File;

=head1 Description

Handle all the API interactions with uploading/downloading files into SCOT

=cut

use Data::Dumper;
use Try::Tiny;
use File::Path qw(make_path);
use File::Slurp;
use File::Type;
use Mojo::Asset::File;
use Digest::MD5 qw(md5_hex);
use Digest::SHA qw(sha1_hex sha256_hex);
use Mojo::JSON qw(decode_json encode_json);
use MIME::Base64;

use strict;
use warnings;
use base 'Mojolicious::Controller';

sub upload {
    my $self    = shift;
    my $env     = $self->env;
    my $log     = $env->log;
    my $mongo   = $env->mongo;
    my $status  = {};
    my @statuses    = ();

    $log->debug("Processing Uploaded File(s)");

    my @uploads = $self->req->upload('upload');
    my $user    = $self->session('user');
    
    # must have an "entry_id" or a target_type/target_id combo
    # entry_id trumps

    my ($entry_id, $target_type, $target_id) = $self->get_targets;

    unless ( defined ($entry_id) ) {
        $entry_id = 0; # this will be the parent of the new entry
    }

    my ($group_href,$year) = 
        $self->get_groups_and_year($target_type, $target_id);

    UPLOAD:
    foreach my $upload (@uploads) {
        my $size    = $upload->size;
        my $name    = $upload->filename;
        my $dir     = join('/',
                           $env->filestorage,
                           $year,
                           $target_type,
                           $target_id);
        
        unless ( -d $dir ) {
            make_path($dir, 0775);
        }
        my $fqn = $dir . '/' . $name;
        if ( -e $fqn ) {
            $fqn .= ".".time();
        }

        $upload = $upload->move_to($fqn);

        if ( $! ) {
            $status = { 
                status  => 'failed',
                reason  => "$!",
                file    => $name,
            };
        }
        else {
            $status = {
                status  => 'ok',
                file    => $fqn,
            };
        }

        my $content_type    = $self->get_filetype($fqn);
        my $filedata        = read_file($fqn);
        my $filehref        = $self->hash_file($filedata);

        $filehref->{filename}   = $name;
        $filehref->{size}       = $size;
        $filehref->{directory}  = $dir;
        $filehref->{groups}     = $group_href;

        my $fileobj = $mongo->collection('File')->create($filehref);

        unless ( $fileobj ) {
            $log->error("Failed creation of file object ",
                        { filter => \&Dumper, value => $filehref });
            next UPLOAD;
        }

        $status->{id} = $fileobj->id;

        my $newentry = $self->create_file_upload_entry(
            $fileobj, $entry_id, $target_type, $target_id
        );

        my $newid;
        unless ($newentry) {
            $log->error("Failed to create file upload entry!");
            $newid  = $entry_id;
        }
        $newid = $newentry->id;


        $self->link_file($fileobj, $newid, $target_type, $target_id);
        push @statuses, $status;
    }
    # TODO: think about harmonizing this with the returns that are expected
    # in API.pm
    $self->render(
        status  => 200, 
        json    => \@statuses);
}

sub create_file_upload_entry {
    my $self        = shift;
    my $fileobj     = shift;
    my $entry_id    = shift;
    my $target_type = shift;
    my $target_id   = shift;
    my $fid         = $fileobj->id;
    my $env         = $self->env;
    my $mongo       = $env->mongo;
    my $log         = $env->log;
    my $htmlsrc     = <<EOF;
<div class="fileinfo">
    <table>
        <tr>
            <th>File Id</th>%d</td>
            <th>Filename</th><td>%s</td>
            <th>Size</th><td>%s</td>
            <th>md5</th><td>%s</td>
            <th>sha1</th><td>%s</td>
            <th>sha256</th><td>%s<d>
            <th>notes</th><td>%s</td>
    </table>
    <a href="/scot/file/%d?download=1">
        Download
    </a>
</div>
EOF
    my $html = sprintf( $htmlsrc,
        $fileobj->id,
        $fileobj->filename,
        $fileobj->size,
        $fileobj->md5,
        $fileobj->sha1,
        $fileobj->sha256,
        $fileobj->notes,
        $fileobj->id);

    my $entry_href  = {
        parent  => $entry_id,
        body    => $html,
        groups  => $fileobj->groups,
    };

    my $col     = $mongo->collection('Entry');
    my $lcol    = $mongo->collection('Link');
    my $entry   = $col->create($entry_href);

    $lcol->link_objects($fileobj, $entry);
    $lcol->create_link(
        { type => "entry", id => $entry->id },
        { type => $target_type, id => $target_id },
    );
}

sub link_file {
    my $self        = shift;
    my $fileobj     = shift;
    my $entry_id    = shift;
    my $target_type = shift;
    my $target_id   = shift;
    my $env         = $self->env;
    my $mongo       = $env->mongo;
    my $log         = $env->log;

    my $file_href   = { type => "file", id => $fileobj->id };
    my $target_href = { type => $target_type, id => $target_id };
    my $entry_href  = { type => "entry", id => $entry_id };

    my $linkcol = $mongo->collection('Link');

    unless ( $linkcol->create_link($file_href, $target_href) ) {
        $log->error("Error: failed to link file to target");
    }
    unless ( $linkcol->create_link($file_href, $entry_href) ) {
        $log->error("Error: failed to link file to entry");
    }
}

sub get_groups_and_year {
    my $self    = shift;
    my $type    = shift;
    my $id      = shift;
    my $env     = $self->env;
    my $log     = $env->log;
    my $mongo   = $env->mongo;

    my $col = $mongo->collection(ucfirst($type));
    my $obj = $col->find_iid($id);

    my $nowdt   = DateTime->now();

    unless ( $obj ) {
        $log->error("Failed to get target object!");
        return $env->default_groups, $nowdt->year;
    }

    my $dt = DateTime->from_epoch(epoch => $obj->when);

    return $obj->groups, $dt->year;
}




sub hash_file {
    my $self    = shift;
    my $data    = shift;
    my %hashes  = (
        md5     => md5_hex($data),
        sha1    => sha1_hex($data),
        sha256  => sha256_hex($data),
    );
    return wantarray ? %hashes : \%hashes;
}

sub get_targets {
    my $self    = shift;
    my $env     = $self->env;
    my $log     = $env->log;
    my $mongo   = $env->mongo;


    my $entry_id   = $self->param('entry_id');
    my $target_id;
    my $target_type;

    unless ( $entry_id ) {
        $entry_id   = 0; # this will be the parent of the file upload entry
        $target_type    = $self->param('target_type');
        $target_id      = $self->param('target_id') + 0;
        my $msg;

        unless ( $target_type ) {
            $msg = "You must provide target_type and target_id, or entry_id";
            $log->error($msg);
            $self->render({
                status  => 400,
                json    => { error_msg => $msg },
            });
            return undef, undef, undef;
        }

        my $collection = $mongo->collection(ucfirst($target_type));

        unless ($collection) {
            $msg    = "invalid collection $target_type as target";
            $log->error($msg);
            $self->render({
                status  => 400,
                json    => { error_msg => $msg }
            });
            return undef, undef, undef;
        }
    }
    else {
        # we could trust/require the client to provide both entry_id
        # and target_type/id but a bug in the client would produce weird 
        # links.  
        my $msg;
        ($target_type, $target_id) = 
            $mongo->collection('Link')->get_entry_target($entry_id);
        unless ($target_type) {
            $msg    = "Error get entry $entry_id target";
            $log->error($msg);
            $self->render({
                status  => 400,
                json    => { error_msg => $msg }
            });
            return undef, undef, undef;
        }
    }
    return $entry_id, $target_type, $target_id;
}

sub get_filetype {
    my $self    = shift;
    my $name    = shift;
    my $path    = sprintf("<%s", $name);
    my $file_type   = File::Type->new();
    my $content_type    = $file_type->mime_type($path);
    return $content_type;
}


    






1;