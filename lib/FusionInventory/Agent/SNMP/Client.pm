package FusionInventory::Agent::SNMP::Client;

use strict;
use warnings;

use Encode qw(encode);
use English qw(-no_match_vars);
use Net::SNMP;

sub new {
    my ($class, %params) = @_;

    die "no hostname parameters" unless $params{hostname};

    my $version =
        ! $params{version}       ? 'snmpv1'  :
        $params{version} eq '1'  ? 'snmpv1'  :
        $params{version} eq '2c' ? 'snmpv2c' :
        $params{version} eq '3'  ? 'snmpv3'  :
                                     undef   ;

    die "invalid SNMP version $params{version}" unless $version;

    my $self;

    # shared options
    my %options = (
        -retries  => 0,
        -version  => $version,
        -hostname => $params{hostname},
    );
    $options{'-timeout'} = $params{timeout} if $params{timeout};

    # version-specific options
    if ($version eq 'snmpv3') {
        # only username is mandatory
        $options{'-username'}     = $params{username};
        $options{'-authprotocol'} = $params{authprotocol}
            if $params{authprotocol};
        $options{'-authpassword'} = $params{authpassword}
            if $params{authpassword};
        $options{'-privprotocol'} = $params{privprotocol}
            if $params{privprotocol};
        $options{'-privpassword'} = $params{privpassword}
            if $params{privpassword};
    } else { # snmpv2c && snmpv1 #
        $options{'-community'} = $params{community};
        $self->{community} = $params{community};
    }

    ($self->{session}, my $error) = Net::SNMP->session(%options);
    if (!$self->{session}) {
        die "no response from host $params{hostname}\n"
            if $error =~ /^No response from remote host/;
        die "authentication error on host $params{hostname}\n"
            if $error =~ /^Received usmStats(WrongDigests|UnknownUserNames)/;
        die $error . "\n";
    }

    if ($version ne 'snmpv3') {
        my $oid = '.1.3.6.1.2.1.1.1.0';
        my $response = $self->{session}->get_request(
            -varbindlist => [$oid]
        );
        die "no response from host $params{hostname}\n"
            if !$response;
        die "no response from host $params{hostname}\n"
            if $response->{$oid} =~ /No response from remote host/;
    }

    bless $self, $class;

    return $self;
}

sub switch_vlan_context {
    my ($self, $vlan_id) = @_;

    my $version_id = $self->{session}->version();

    my $version =
        $version_id == 0 ? 'snmpv1'  :
        $version_id == 1 ? 'snmpv2c' :
        $version_id == 3 ? 'snmpv3'  :
                             undef   ;

    my $error;
    if ($version eq 'snmpv3') {
        $self->{context} = 'vlan-' . $vlan_id;
    } else {
        # save original session
        $self->{oldsession} = $self->{session} unless $self->{oldsession};
        ($self->{session}, $error) = Net::SNMP->session(
            -timeout   => $self->{session}->timeout(),
            -retries   => 0,
            -version   => $version,
            -hostname  => $self->{session}->hostname(),
            -community => $self->{community} . '@' . $vlan_id
        );
    }

    die $error unless $self->{session};
}

sub reset_original_context {
    my ($self) = @_;

    my $version_id = $self->{session}->version();

    my $version =
        $version_id == 0 ? 'snmpv1'  :
        $version_id == 1 ? 'snmpv2c' :
        $version_id == 3 ? 'snmpv3'  :
                             undef   ;

    if ($version eq 'snmpv3') {
        delete $self->{context};
    } else {
        $self->{session} = $self->{oldsession};
        delete $self->{oldsession};
    }
}

sub get {
    my ($self, $oid) = @_;

    return unless $oid;

    my $session = $self->{session};
    my %options = (-varbindlist => [$oid]);
    $options{'-contextname'} = $self->{context} if $self->{context};

    my $response = $session->get_request(%options);

    return unless $response;

    return if $response->{$oid} =~ /noSuchInstance/;
    return if $response->{$oid} =~ /noSuchObject/;
    return if $response->{$oid} =~ /No response from remote host/;


    my $value = $response->{$oid};

    return $value;
}

sub walk {
    my ($self, $oid) = @_;

    return unless $oid;

    my $session = $self->{session};
    my %options = (-baseoid => $oid);
    $options{'-contextname'}    = $self->{context} if $self->{context};
    $options{'-maxrepetitions'} = 1                if $session->version() != 0;

    my $response = $session->get_table(%options);

    return unless $response;

    my $values;
    my $offset = length($oid) + 1;

    foreach my $oid (keys %{$response}) {
        my $value = $response->{$oid};
        $values->{substr($oid, $offset)} = $value;
    }

    return $values;
}

1;
__END__

=head1 NAME

FusionInventory::Agent::SNMP::Client - SNMP client

=head1 DESCRIPTION

This is the object used by the agent to perform SNMP queries on live host.

=head1 METHODS

=head2 new(%params)

The constructor. The following parameters are allowed, as keys of the %params
hash:

=over

=item version (mandatory)

Can be one of:

=over

=item '1'

=item '2c'

=item '3'

=back

=item timeout

The transport layer timeout

=item hostname (mandatory)

=item community

=item username

=item authpassword

=item authprotocol

=item privpassword

=item privprotocol

=back

=head2 switch_vlan_context($vlan_id)

Switch to a new vlan-specific context.

With SNMPv1 and SNMPv2, this creates a new SNMP connection, using a community
derived from original one, with vlan ID appended as a suffix. With SNMPv3,
ensure all subsequent requests use relevant context.

=head2 reset_original_context()

Reset to original context.

=head2 get($oid)

This method returns a single value, corresponding to a single OID. The value is
normalised to remove any control character, and hexadecimal mac addresses are
translated into plain ascii.

=head2 walk($oid)

This method returns an hashref of values, indexed by their OIDs, starting from
the given one. The values are normalised to remove any control character, and
hexadecimal mac addresses are translated into plain ascii.
