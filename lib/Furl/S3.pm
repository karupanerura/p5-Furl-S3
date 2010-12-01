package Furl::S3;

use strict;
use warnings;
use Class::Accessor::Lite;
use Furl;
use Digest::HMAC_SHA1;
use MIME::Base64 qw(encode_base64);
use HTTP::Date;
use Data::Dumper;
use XML::LibXML;
use XML::LibXML::XPathContext;
use Furl::S3::Error;
use Params::Validate qw(:types validate_with validate_pos);
use Carp ();

Class::Accessor::Lite->mk_accessors(qw(aws_access_key_id aws_secret_access_key secure furl endpoint));

our $VERSION = '0.01';
our $DEFAULT_ENDPOINT = 's3.amazonaws.com';
our $XMLNS = 'http://s3.amazonaws.com/doc/2006-03-01/';

sub new {
    my $class = shift;
    validate_with( 
        params => \@_, 
        spec => {
            aws_access_key_id => 1,
            aws_secret_access_key => 1,
        },
        allow_extra => 1,
    );
    my %args = @_;
    my $aws_access_key_id = delete $args{aws_access_key_id};
    my $aws_secret_access_key = delete $args{aws_secret_access_key};
    Carp::croak("aws_access_key_id and aws_secret_access_key are mandatory") unless $aws_access_key_id && $aws_secret_access_key;
    my $secure = delete $args{secure} || '0';
    my $endpoint = delete $args{endpoint} || $DEFAULT_ENDPOINT;
    my $furl = Furl->new( 
        agent => '$class/'. $VERSION,
        %args,
    );
    my $self = bless {
        endpoint => $endpoint,
        secure => $secure,
        aws_access_key_id => $aws_access_key_id,
        aws_secret_access_key => $aws_secret_access_key,
        furl => $furl,
    }, $class;
    $self;
}

sub _trim {
    my $str = shift;
    $str =~ s/^\s+//;
    $str =~ s/\s+$//;
    $str;
}

sub _remove_quote {
    my $str = shift;
    $str =~ s/^"//;
    $str =~ s/"$//;
    $str;
}

sub _boolean {
    my $str = shift;
    if ( $str eq 'false' ) {
        return 0;
    }
    return 1;
}

sub _string_to_sign {
    my( $self, $method, $resource, $headers ) = @_;
    $headers ||= {};
    my %headers_to_sign;
    while (my($k, $v) = each %{$headers}) {
        my $key = lc $k;
        if ( $key =~ /^(content-md5|content-type|date)$/ or 
                 $key =~ /^x-amz-/ ) {
            $headers_to_sign{$key} = _trim($v);
        }
    }
    my $str = "$method\n";
    $str .= delete($headers_to_sign{'content-md5'}) || '';
    $str .= "\n";
    $str .= delete($headers_to_sign{'content-type'}) || '';
    $str .= "\n";
    $str .= delete($headers_to_sign{'date'}) || '';
    $str .= "\n";
    for my $key( sort keys %headers_to_sign ) {
        $str .= "$key:$headers_to_sign{$key}\n";
    }
    my( $path, $query ) = split /\?/, $resource;
    # sub-resource.
    if ( $query && $query =~ m{^(acl|policy|location|versions)$}) {
        $str .= $resource;
    }
    else {
        $str .= $path;
    }

    $str;
}

sub _sign {
    my( $self, $str ) = @_;
    my $hmac = Digest::HMAC_SHA1->new( $self->aws_secret_access_key );
    $hmac->add( $str );
    encode_base64( $hmac->digest );
}

sub _path_query {
    my( $self, $path, $q ) = @_;
    $path = '/'. $path unless $path =~ m{^/};
    my $qs = ref($q) eq 'HASH' ? 
        join('&', map { $_. '='. $q->{$_} } keys %{$q}) : $q;
    $path .= '?'. $qs if $qs;
    $path;
}


sub request {
    my $self = shift;
    my( $method, $bucket, $key, $params, $headers, $furl_options ) = @_;
    validate_pos( @_, 1, 1, 0, 
                  { type => HASHREF | UNDEF | SCALAR , optional => 1, }, 
                  { type => HASHREF | UNDEF , optional => 1, },
                  { type => HASHREF | UNDEF , optional => 1, }, );

    $key ||= '';
    $params ||= +{};
    $headers ||= +{};
    $furl_options ||= +{};
    my %h;
    while (my($key, $val) = each %{$headers}) {
        $key =~ s/_/-/g; # content_type => content-type
        $h{lc($key)} = $val
    }
    $h{'date'} ||= time2str(time);
    my $path_query = $self->_path_query(join('/', $bucket, $key), $params);
    $path_query =~ s{//}{/};
    my $string_to_sign = 
        $self->_string_to_sign( $method, $path_query, \%h );
    my $signed_string = $self->_sign( $string_to_sign );
    my $auth_header = 'AWS '. $self->aws_access_key_id. ':'. $signed_string;
    $h{'authorization'} = $auth_header;
    my @h = %h;
    $self->furl->request(
        method => $method,
        scheme => ($self->secure ? 'https' : 'http'),
        host => $self->endpoint,
        path_query => $path_query,
        headers => \@h,
        %{$furl_options},
    );
}

sub _create_xpc {
    my( $self, $string ) = @_;
    my $xml = XML::LibXML->new;
    my $doc = $xml->parse_string( $string );
    my $xpc = XML::LibXML::XPathContext->new( $doc );
    $xpc->registerNs('s3' => $XMLNS);
    return $xpc;
}

sub list_buckets {
    my $self = shift;
    my $res = $self->request( 'GET', '/' );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    my $xpc = $self->_create_xpc( $res->content );
    my @buckets;
    for my $node($xpc->findnodes('/s3:ListAllMyBucketsResult/s3:Buckets/s3:Bucket')) {
        my $name = $xpc->findvalue('./s3:Name', $node);
        my $creation_date = $xpc->findvalue('./s3:CreationDate', $node);
        push @buckets, +{
            name => $name,
            creation_date => $creation_date,
        };
    } 
    return +{
        buckets => \@buckets,
        owner => +{
            id => $xpc->findvalue('/s3:ListAllMyBucketsResult/s3:Owner/s3:ID'),
            display_name => $xpc->findvalue('/s3:ListAllMyBucketsResult/s3:Owner/s3:DisplayName'),
        },
    }
}

sub create_bucket {
    my $self = shift;
    my( $bucket, $headers ) = @_;
    validate_pos( @_, 1,  
                  { type => HASHREF, optional => 1, } );

    my $res = $self->request( 'PUT', $bucket, undef, undef, $headers );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ) );
    }
    return $res->is_success;
}

sub delete_bucket {
    my $self = shift;
    my( $bucket ) = @_;
    validate_pos( @_, 1 );
    my $res = $self->request( 'DELETE', $bucket );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ) );
    }
    return $res->is_success;
}

sub list_objects {
    my $self = shift;
    my( $bucket, $params ) = @_;
    validate_pos( @_, 1, { type => HASHREF, optional => 1 });
    my $res = $self->request( 'GET', $bucket, undef, $params );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    my $xpc = $self->_create_xpc( $res->content );
    my @contents;
    for my $node($xpc->findnodes('/s3:ListBucketResult/s3:Contents')) {
        push @contents, +{
            key => $xpc->findvalue('./s3:Key', $node),
            etag => _remove_quote( $xpc->findvalue('./s3:ETag', $node) ),
            storage_class => $xpc->findvalue('./s3:StorageClass', $node),
            last_modified => $xpc->findvalue('./s3:LastModified', $node),
            size => $xpc->findvalue('./s3:Size', $node),
            owner => +{
                id => $xpc->findvalue('./s3:Owner/s3:ID', $node),
                display_name => $xpc->findvalue('./s3:Owner/s3:DisplayName', $node),
            },
        };
    }
    my @common_prefixes;
    for my $node($xpc->findnodes('/s3:ListBucketResult/s3:CommonPrefixes')) {
        push @common_prefixes, +{
            prefix => $xpc->findvalue('./s3:Prefix', $node),
        };
    }
    return +{
        name => $xpc->findvalue('/s3:ListBucketResult/s3:Name'),
        is_truncated => _boolean($xpc->findvalue('/s3:ListBucketResult/s3:IsTruncated')),
        delimiter => $xpc->findvalue('/s3:ListBucketResult/s3:Delimiter'),
        max_keys => $xpc->findvalue('/s3:ListBucketResult/s3:MaxKeys'),
        marker => $xpc->findvalue('/s3:ListBucketResult/s3:Marker'),
        contents => \@contents,
        common_prefixes => \@common_prefixes,
    };
}

sub create_object {
    my $self = shift;
    my( $bucket, $key, $content, $headers ) = @_;
    validate_pos( @_, 1, 1, 
                  { type => HANDLE | SCALAR }, 
                  { type => HASHREF, optional => 1 } );
    my $res = $self->request( 'PUT', $bucket, $key, undef, $headers, +{ content => $content });
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    return $res->is_success;
}

sub create_object_from_file {
    my $self = shift;
    my( $bucket, $key, $filename, $headers ) = @_;
    validate_pos( @_, 1, 1, 1,
                  { type => HASHREF, optional => 1 } );

    $headers ||= {};
    my $has_ct = 0;
    for my $key( keys %{$headers} ) {
        if (lc($key) =~ qr/^(content_type|content-type)$/) {
            $has_ct = 1;
            last ;
        }
    }
    unless ( $has_ct ) {
        require File::Type;
        my $ft = File::Type->new;
        my $content_type = $ft->checktype_filename( $filename );
        $headers->{'content_type'} = $content_type;
    }
    open my $fh, '<', $filename or die "$!: $filename";
    $self->create_object( $bucket, $key, $fh, $headers )
}

sub _normalize_response {
    my( $self, $res, $is_head ) = @_;
    my %res;
    my $headers = $res->headers;
    for my $key( $headers->keys ) {
        my @val = $headers->header( $key );
        $res{$key} = (@val > 1) ? \@val : $val[0];
    }
    # remove etag's double quote.
    if ( my $etag = $headers->header('etag') ) {
        $res{etag} = _remove_quote( $etag );
    }
    $res{content_length} = $headers->content_length;
    $res{content_type} = $headers->content_type;
    $res{last_modified} = $headers->last_modified;
    unless ( $is_head ) {
        $res{content} = $res->content;
    }
    return \%res;
}


sub get_object {
    my $self = shift;
    my( $bucket, $key, $headers, $furl_options ) = @_;
    validate_pos( @_, 1, 1, 
                  { type => HASHREF, optional => 1 },
                  { type => HASHREF, optional => 1 }, );
    my $res = $self->request( 'GET', $bucket, $key, undef, $headers, $furl_options );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    $self->_normalize_response( $res );
}

sub get_object_to_file {
    my $self = shift;
    my( $bucket, $key, $filename ) = @_;
    validate_pos( @_, 1, 1, 1 );
    open my $fh, '>', $filename or die "$!: $filename";
    $self->get_object( $bucket, $key, {}, {
        write_file => $fh,
    });
}

sub head_object {
    my $self = shift;
    my( $bucket, $key, $headers ) = @_;
    validate_pos( @_, 1, 1, { type => HASHREF, optional => 1 } );
    my $res = $self->request( 'HEAD', $bucket, $key, undef, $headers );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    $self->_normalize_response( $res, 1 );
}

sub delete_object {
    my $self = shift;
    my( $bucket, $key ) = @_;
    validate_pos( @_, 1, 1 );
    my $res = $self->request( 'DELETE', $bucket, $key );
    unless ( $res->is_success ) {
        return $self->error( Furl::S3::Error->new( $res, $res->content ));
    }
    return $res->is_success;
}

sub clear_error {
    my $self = shift;
    delete $self->{_error};
}

sub error {
    my $self = shift;
    if ( $_[0] ) {
        $self->{_error} = $_[0];
        return ;
    }
    $self->{_error};
}

1;


__END__

=head1 NAME

Furl::S3 - Furl based S3 client library.

=head1 SYNOPSIS

  use Furl::S3;

  my $s3 = Furl::S3->new( 
      aws_access_key_id => '...', 
      aws_secret_access_key => '...',
  );
  $s3->create_bucket($bucket) or die $s3->error;

  my $res = $s3->list_objects($bucket) or die $s3->error;
  for my $obj(@{$res->{contents}}) {
      printf "%s\n", $obj->{key};
  }

=head1 DESCRIPTION

This module uses L<Furl> lightweight HTTP client library and provides very simple interfaces to Amazon Simple Storage Service (Amazon S3)

for more details. see Amazon S3's developer guide and API References.

http://docs.amazonwebservices.com/AmazonS3/2006-03-01/dev/

http://docs.amazonwebservices.com/AmazonS3/2006-03-01/API/

=head1 METHODS

=head2 Furl::S3->new( %args )

returns a new Furl::S3 object.

I<%args> are below.

=over

=item aws_access_key_id 

AWS Access Key ID

=item aws_secret_access_key

AWS Secret Access Key.

=item secure

boolean flag. uses SSL connection or not.

=item endpoint

S3 endpoint hostname. the default value is I<s3.amazonaws.com>

other parmeters are passed to Furl->new. see L<Furl> documents.

=back

=head2 list_buckets

list all buckets.
returns a HASH-REF

  {
      'owner' => {
        'id' => '...',
        'display_name' => '..'
      },
      'buckets' => [
          {
              'creation_date' => '2010-11-30T00:00:00.000Z',
              'name' => 'Your bucket name'
          },
          #...
      ]
  }

=head2 create_bucket($bucket, [ \%headers ])

create new bucket.
returns a boolean value. 

=head2 delete_bucket($bucket);

delete bucket.
returns a boolean value.

=head2 list_objects($bucket, [ \%params ])

list all objects in specified bucket.
returna a HASH-REF 


  {
      'marker' => '',
      'common_prefixes' => [],
      'max_keys' => '10',
      'contents' => [
          {
               'owner' => {
                   'id' => '..'
                   'display_name' => '...'
               },
               'etag' => 'xxx',
               'storage_class' => 'STANDARD',
               'last_modified' => '2010-12-01T00:00:00.000Z',
               'size' => '10000',
               'key' => 'foo/bar/baz.txt'
          },
          #... 
      ],
      'name' => 'Your bucket name',
      'delimiter' => '',
      'is_truncated' => 1
   }

\%params are below.
see Amazon S3 documents for detail.

http://docs.amazonwebservices.com/AmazonS3/2006-03-01/API/index.html?RESTBucketGET.html

=over

=item delimiter

=item marker

=item max-keys

=item prefix

=back

=head2 create_object($bucket, $key, $content, [ \%headers ]);

create new object.
$content is passed to Furl. so you can specify scalar value or FileHandle object.

you can set any request headers. example is below.

  open my $fh, '<', 'image.jpg' or die $!;
  $s3->create_object('you-bucket', 'public.jpg', $fh, {
      content_type => 'image/jpg',
      'x-amz-acl' => 'public-read',
  });
  close $fh;

=head2 get_object($bucket, $key, [ \%headers, \%furl_options ]);

get object.

\%furl_options are passed to Furl->request method. so you can use write_code or write_file to handle response.

returns a HASH-REF.

  {
      content => $content, 
      content_length => '..',
      etag => '...',
      content_type => '...',
      last_modified => '...',
      'x-amz-meta-foo' => 'metadata'
  }

=head2 get_object_to_file($bucket, $key, $filename);

get object and write to file.
returns a boolean value.

=head2 head_object($bucket, $key, [ \%headers ]);

get object's metadata.
returns a HASH-REF

  {
      content_length => '..',
      etag => '...',
      content_type => '...',
      last_modified => '...',
      'x-amz-meta-foo' => 'metadata'
  }

=head2 delete_object($bucket, $key);

delete object.
returns a boolean value.

=head1 AUTHOR

Tomohiro Ikebe E<lt>ikebe {at} livedoor.jpE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
