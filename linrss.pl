#!/usr/bin/perl -w
    
use Getopt::Long qw( GetOptions );
use IO::Termios;
use Time::Out qw(timeout);
use Time::HiRes qw( usleep );
use Switch;


# Use cases...
#
# --- Query either the radio or a stored codeplug...
# linrss --radio /dev/ttyS0 query  { serialnum | mode={1..32} | other globals| .... }
# linrss --radio /dev/ttyS0 query  address=0xB28B bytes=3
#
# --- Set mode 12 tuning...
# linrss --radio /dev/ttyS0 set mode=12 name=12 rx=144.235 tx=144.235 rx_tpl=100 tx_tpl=100
#
# --- Blank 
# linrss --radio /dev/ttyS0 blank  (Not implemented yet!)
#
# --- Download the radio's codeplug to a file
# linrss --radio /dev/ttyS0 --codeplug /home/myers/radio/333AUQ3431.codeplug download
#
# --- Upload a codeplug file to the radio
# linrss --radio /dev/ttyS0 --codeplug /home/myers/radio/333AUQ3431.codeplug upload
# 



&consoleLog("LinRSS v0.2: Copyright 2016 by David Myers, KI6GEQ\n");
&consoleLog("Linux-based programming software for Motorola Maxtrac radios.\n");
&consoleLog("Released under the terms of the Gnu Public License (GPL).\n");
&consoleLog("\nWARNING: This software has not been tested against all configurations\n");
&consoleLog("         and models of Motorola Maxtrac radios.\n");
&consoleLog("         USE AT YOUR OWN RISK.\n\n");


# Process command line options
my $radiodevice = "";
my $codeplugfile = "";
my @cmdarray;
my $optionsstr = "";
my $PORT = "/dev/ttyS0";
my $CODEPLUG;

my $TERM; 
my $ATTRS;
my $BASE_FREQUENCY;
my $FREQUENCY_STEP = 5;  # kHz
my $MODE_COUNT;
my $MODE_BASE_ADDRESS;
my $SERIAL_NUMBER;
my $PL_CONSTANT = 4861000;
my $CODEPLUG_BASE_ADDRESS = 0xB600;
my $CODEPLUG_EXTENDED_ADDRESS = 0x7800;



GetOptions('radio=s' => \$PORT,
	   'codeplug=s' => \$CODEPLUG);



&initializeSerialPort;

if (&resetRadio) {
    print "Error: Unable to reset radio.\n";
}

if (&checkCommunications) {
    die "Error: Unable to establish communications with radio.  Exiting.\n"
}

    # my $pkt = &genHighSpeedPacket();
    # &transmit($pkt);
    # my $recvbuf = &receive();
    # my @packetarray = &parsePacketStream($recvbuf);
    # if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x24) {
    # 	system("./oddbaud $PORT 7600");
    # }

&interrogate;


# create a default file name if the user didn't specify one
if (!$CODEPLUG) {
    $CODEPLUG = $SERIAL_NUMBER . ".codeplug";
}

# parse the remaining commands in @ARGV
&parseCommand(\@ARGV);

&closeAndExit;


sub parseCommand {
    my @cmd = @{ shift @_ };

    # The 0th element must be the command directive.
    # Any subsequent elements are parameters to the command.

    my $c = shift(@cmd);
    switch ($c) {
	case 'query' {
	    if (&parseQueryCommand(\@cmd)) {
		&consoleLog("---> Query failed.\n");
	    }
	}

	case 'set' {
	    my $resultcode = &parseSetCommand(\@cmd);
	    if ($resultcode) {
		&consoleLog("---> Error: set operation failed.\n");
	    }
	}	

	case 'identify' {
	    &radioIdentificationScript;
	}
	
	case 'upload' {
	    if ($CODEPLUG) {
		open(SFH, "<:unix", $CODEPLUG) || die "---> Error: couldn't open " . $CODEPLUG . "\n";
		binmode(SFH);
	    } else {
		die "---> Error: No codeplug file specified.\n";
	    }
	    &uploadCodeplug;
	    &resetRadio;
	}

	case 'download' {
	    if ($CODEPLUG) {
		open(TFH, ">:unix", $CODEPLUG) || die "---> Error: couldn't open " . $CODEPLUG . "\n";
		binmode(TFH);
	    } else {
		die "---> Error: No codeplug file specified.\n";
	    }
	    &downloadCodeplug;
	}
    }
}



sub parseQueryCommand {
    my @options = @{ shift @_ };

    if ($options[0] =~ /mode=/) {
	(my $junk, my $mode) = split(/=/, $options[0]);

	if ($mode > $MODE_COUNT) {
	    &consoleLog("---> Error: Radio only has " . $MODE_COUNT . " modes.\n");
	    return -1;
	}
	
	my %mode = &getMode($mode);
	
    	if (%mode) {
	    print "Mode " . $mode{mode_num} . ": ";
	    print "Displays as \"" . $mode{mode_name} . "\"";
	    print "; Rx " . $mode{rx_frequency} . " Mhz";
	    if ($mode{rx_squelch_type}) {
		print " (" . $mode{rx_squelch_val} . " " . $mode{rx_squelch_type} . ")";
	    }
	    print "; Tx " . $mode{tx_frequency} . " Mhz";
	    if ($mode{tx_squelch_type}) {
		print " (" . $mode{tx_squelch_val} . " " . $mode{tx_squelch_type} . ")";
	    }
	    
	    print "\n";
	} else {
	    &consoleLog("---> Error: No mode data returned; unknown reason.\n");
	    return -1;
	}

	return 0;
    }

    if ($options[0] =~ /modes/) {
	my $mode_count = &getModeCount();
	print "Radio has " . $mode_count . " modes.\n";
	return 0;
    }

    if ($options[0] =~ /address=(\w+)/) {
	my $address = $1; 
	my $hexaddress = hex($address); 
	if ($options[1] =~ /bytes=(\d+)/) {
	    my $bytes = $1;
	    if ($bytes > 27) { $bytes = 27; }
	    my $packet = genPacket('request_data', $bytes, $hexaddress, ());
	    &transmit($packet);
	    my $recvbuf = &receive();
	    my @packetarray = &parsePacketStream($recvbuf);
	    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
		print $address . ": ";
		for (my $i = 0; $i < $bytes; $i++) {
		    printf("%02X ", $packetarray[1]{bytes}[$i+1]);
		}
		print "\n";
		print "        ";
		for ($i = 0; $i < $bytes; $i++) {
		    if ($packetarray[1]{bytes}[$i+1] >= 32 && $packetarray[1]{bytes}[$i+1] < 127) {
			print " " . chr($packetarray[1]{bytes}[$i+1]) . " ";
		    } else {
			printf(" . ");
		    }
		    
		}
		print "\n";
	    }
	}

	return 0;
    }

    &consoleLog("---> Error: you didn't specify anything to query.  See help.\n");
    return -1;
}


sub parseSetCommand {
    my @params  = @{ shift @_ };
    my $mode;
    my $name;
    my $rxfreq;
    my $txfreq;
    my $rxtpl;
    my $txtpl;
    my %oldpacket;

    # For example, 
    # --command set mode=12 name=12 rx=144.235 tx=144.235 rx_tpl=100 tx_tpl=100


    foreach $param (@params) {
	if ($param =~ /mode=(\d+)/) {
	    $mode = $1;
	}

	if ($param =~ /name=(\d+)/) {
	    $name = $1;
	}
	
	# Check for Rx frequencies of the forms
        # XYZ or XYZ.abc 
	if ($param =~ /rx=(\d+)/) {
	    $rxfreq = $1;
	}

	if ($param =~ /rx=(\d+\.\d*)/) {
	    $rxfreq = $1;
	}

	if ($param =~ /tx=(\d+)/) {
	    $txfreq = $1;
	}
	
	if ($param =~ /tx=(\d+\.\d+)/) {
	    $txfreq = $1;
	}
	
	if ($param =~ /rx_tpl=(\d+)/) {
	    $rxtpl = $1;
	}

	if ($param =~ /tx_tpl=(\d+)/) {
	    $txtpl = $1;
	}

	if ($param =~ /rx_dpl=(\d+)/) {
	    $rxdpl = $1;
	}

	if ($param =~ /tx_dpl=(\d+)/) {
	    $txdpl = $1;
	}
    }

    if ($mode && $mode >= 1 && $mode <= $MODE_COUNT) {
	%oldpacket = &getMode($mode);
    } else {
	&consoleLog("---> No mode specified, or mode specified was greater than radio's mode count.\n");
	return; 
    }

    if ($name) {
	$oldpacket{mode_name} = substr($name, 0, 2);
    }

    if ($rxfreq) {
	$oldpacket{rx_frequency} = $rxfreq;
    }

    if ($txfreq) {
	$oldpacket{tx_frequency} = $txfreq;
    }

    if ($rxtpl) {
	$oldpacket{rx_squelch_val} = $rxtpl;
	$oldpacket{rx_squelch_type} = 'TPL';
    }

    if ($txtpl) {
	$oldpacket{tx_squelch_val} = $txtpl;
	$oldpacket{tx_squelch_type} = 'TPL';
    }

    if ($rxdpl) {
	$oldpacket{rx_squelch_val} = $rxdpl;
	$oldpacket{rx_squelch_type} = 'DPL';
    }

    if ($txdpl) {
	$oldpacket{tx_squelch_val} = $txdpl;
	$oldpacket{tx_squelch_type} = 'DPL';
    }


    my @newpacketarray = &genSetModePackets($mode, %oldpacket);
    my @thispacket;
    my $recvbuf;
    my $error = 0;

    foreach $pkt (@newpacketarray) {
    	&transmit($pkt);
    	$recvbuf = &receive();
    	@thispacket = parsePacketStream($recvbuf);
    	if ($thispacket[1]{lead_in} eq 'radio' && $thispacket[1]{function_code} == 0x24) {
    	    # Lookin' good so far.  Spec says to sleep for 10ms per byte written.
	    # Since we generally write 8-byte blocks, we'll just sleep for
	    # 80 ms (which is 80,000 u-seconds).
	    usleep(80000);
    	} else {
    	    $error = 1;
    	    last;
    	}
    }

    return $error;
}



sub downloadCodeplug {
    # The number of modes will determine how much data we need to download.
    #
    # A $MODE_COUNT <= 16 will require only the memory block between B600 - B7FF.
    # This is "64 blocks" in RSS lingo.
    #
    # A $MODE_COUNT > 16 will require the above plus the memory 7800 - 7FFF.
    # This is "320 blocks" in RSS lingo.


    my $i;
    my $j;
    my $pkt;
    my $recvbuf;
    my $bytes_written;
    my $byte;
    my @packetarray;

    
    &consoleLog("Downloading codeplug: ");
    
    for ($i = 0; $i < 64; $i++) {
	$pkt = genPacket('request_data', 8, $CODEPLUG_BASE_ADDRESS + ($i * 8), ());
	&transmit($pkt);
	$recvbuf = &receive;
	@packetarray = &parsePacketStream($recvbuf);
	if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
	    print TFH $packetarray[1]{chars};
	}

	&consoleLog(".");
    }
    

    if ($MODE_COUNT > 16) {
	for ($i = 0; $i < 256; $i++) {
	    $pkt = genPacket('request_data', 8, $CODEPLUG_EXTENDED_ADDRESS + ($i * 8), ());
	    &transmit($pkt);
	    $recvbuf = &receive;
	    @packetarray = &parsePacketStream($recvbuf);
	    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
		print TFH $packetarray[1]{chars};
	    }

	    &consoleLog(".");
	    
	}
    }
    
    &consoleLog(" complete.\n");
    close TFH;

}


sub uploadCodeplug {
    # See comments above in downloadCodeplug for where we put data...

    my $i;
    my $j;
    my $pkt;
    my $buf;
    my $byte;
    my $bytesread;
    my $chunk_address;


    # Read the serial number from the codeplug file.  It will be at offset 20 (decimal) and
    # run for 10 characters

    $bytesread = sysread(SFH, $buf, 30);
    $serialnum = substr($buf, 19, 10);
    if ($serialnum ne $SERIAL_NUMBER) {
	&consoleLog("---> Serial number mismatch; refusing to upload codeplug file.\n");
	close SFH;
	return -1;
    }

    # rewind file
    sysseek(SFH, 0, 0);
    


    &consoleLog( "Uploading codeplug: ");
    
    
    # Upload the lower block of the codeplug into $CODEPLUG_BASE_ADDRESS
    for ($i = 0; $i < 64; $i++) {
	$bytesread = sysread(SFH, $buf, 8);
	if ($bytesread != 8) {
	    last;
	}

	$chunk_address = $CODEPLUG_BASE_ADDRESS + ($i * 8);
	if (&uploadCodeplugChunk($chunk_address, $buf)) {
	    # show an error
	    &consoleLog("!");
	} else {
	    # everything's okay
	    &consoleLog(".");
	}
	# Spec says to delay 10 ms per byte written...
	usleep(80000);
	
    }
    
    for ($i = 0; $i < 256; $i++) {
	$bytesread = sysread(SFH, $buf, 8);
	if ($bytesread != 8) {
	    last;
	}

	$chunk_address = $CODEPLUG_EXTENDED_ADDRESS + ($i * 8);
	if (&uploadCodeplugChunk($chunk_address, $buf)) {
	    &consoleLog("!");
	} else {
	    &consoleLog(".");
	}
	usleep(80000);
	
    }

    print " complete.\n";

    
    close SFH;
}



sub uploadCodeplugChunk {
    my $address = shift;
    my $buf = shift;
    my @bytesarray;
    my @ordarray;
    my $pkt;
    my $recvbuf;
    my @packetarray;

    @bytesarray = split(//, $buf);
    foreach $byte (@bytesarray) {
	push @ordarray, ord($byte);
    }
    $pkt = genPacket('write_data', length($buf), $address, @ordarray);
    &transmit($pkt); 
    $recvbuf = &receive;
    @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x24) {
	return 0;
    } else {
	return -1;
    }
    
}


sub radioIdentificationScript {
    &consoleLog("Radio parameters:\n");
    &consoleLog("   Serial Number: " . $SERIAL_NUMBER . "\n");
    &consoleLog("   Band: ");
    switch ($BASE_FREQUENCY) {
	case 0 {
	    &consoleLog("VHF low band (50MHz).\n");
	}
	
	case 136 {
	    &consoleLog("VHF high band (150 MHz).\n");
	}
	
	case 402.590 {
	    &consoleLog("UHF low band (400 MHz).\n");
	}

	case 804.8625 {
	    &consoleLog("UHF high band (800 MHz).\n");
	}

	case 894.4 {
	    &consoleLog("UHF high band (900 MHz).\n");
	}
	
	else {
	    &consoleLog("unknown band. (This shouldn't happen!)\n");
	}
    }

    &consoleLog("   Frequency Step: " . $FREQUENCY_STEP . " kHz\n");
    &consoleLog("   Modes: " . $MODE_COUNT . "\n");
    my $str = sprintf("   Mode Base Address: 0x%04X\n", $MODE_BASE_ADDRESS);
    &consoleLog($str); 
    
}



sub transmit {
    my $msg = shift;
    my $delayms = shift;
    my $i = 0;

    for ($i = 0; $i < length($msg); $i++) {
    	$TERM->write(substr($msg, $i, 1), 1);
    	if ($delayms) {
    	    usleep($delayms * 1000);
    	}
    }

}


sub receive {
    my $buf = "";
    my $recvd = 0;
    my $retries = 0;
    my $ch;
    my $chars = "";

    # Read characters from the radio one at a time.
    # Note: you get a copy of what you sent in addition to what the radio
    # sends.  

    timeout 1 => sub {
	while ($TERM->read($ch, 1)) {
	    $buf .= $ch;
	    $recvd++;
	}
    };

    if ($@) {
	$retries++;
    }

    if ($retries > 9) {
	&consoleLog("---> No response received from radio.\n");
	return 0;
    }

    if ($recvd == 0) {
	&consoleLog("---> No data received from radio.\n");
    }


    return $buf;
}



sub initializeSerialPort {
    # We use an external Linux program to set the baud rate: 115200 (base rate) / 121 (divisor) = 952
    system("./oddbaud $PORT 952");
    if ($? == -1) {
    	return -1;
    }

    # $TERM and $ATTRS are global in scope
    $TERM = IO::Termios->open($PORT) || die "---> Cannot open $PORT: $!\n";
    $ATTRS = $TERM->getattr;
    $ATTRS->setcsize( 7 );
    $ATTRS->setparity( 'e' );
    $ATTRS->setstop( 1 );
    $TERM->setattr( $ATTRS );
    
    return 0;
}


sub interrogate {
    $SERIAL_NUMBER = &getSerialNumber;
    $BASE_FREQUENCY = &getBand;
    if ($BASE_FREQUENCY > 800) {
	# UHF-high radios use a step frequency of 12.5 kHz.  All
	# others use the default value of 5 kHz.
	$FREQUENCY_STEP = 12.5;
    }
    $MODE_COUNT = &getModeCount;
    $MODE_BASE_ADDRESS = &getModeBaseAddress;
}


sub closeAndExit {
    if ($TERM) {
	$TERM->close();
    }
    exit 0;
}



sub resetRadio {
    my $msg = &genResetPacket();
    &transmit($msg);
    my $recvbuf = &receive();
    if (!$recvbuf) {
	return -1;
    }
    my @packetarray = &parsePacketStream($recvbuf);
    if (@packetarray && $packetarray[1]{function_code} != 0x24) {
	return -1;
    }
    
    return 0;
}


sub checkCommunications {
    my $msg = &genPacket("connection_check", 0, 0x0000, ());
    &transmit($msg);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{function_code} != 0x24) {
	return -1;
    }

    return 0;
}


sub getSerialNumber {
    my $msg = &genQuerySerialNumberPacket();
    &transmit($msg);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{function_code} == 0x38) {
	return $packetarray[1]{chars};
    } else {    
	return 0;
    }

}


sub getBand {
    my $packet = &genPacket('request_data', 1, 0xB63B, ());
    &transmit($packet);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{function_code} == 0x38) {
	my $split = $packetarray[1]{bytes}[1] & 0x12;
	my $band = $packetarray[1]{bytes}[1] & 0x03;
	switch ($band) {
	    case 0 {
		return 136;
	    }

	    case 1 {
		return 402.590;
	    }

	    case 2 {
		# This case is the 800/900 MHz radio.  
		# We need to use $split to tell them apart.
		($split == 0) ? return 804.8625 : return 894.4000;
	    }

	    case 3 {
		return 0;
	    }
	}
    }
}



sub getModeCount {
    my $MODE_COUNT_ADDRESS = 0xB624;
    my $mode_count;

    my $packet = genPacket('request_data', 2, $MODE_COUNT_ADDRESS, ());
    &transmit($packet);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
	# if the first byte is zero, the second byte has the mode count
	if ($packetarray[1]{bytes}[1] == 0x00) {
	    return $packetarray[1]{bytes}[2];
	} else {
	    # otherwise the modes have been shifted to external EEPROM,
	    # which (by definition?) means 32 modes.
	    return 32;
	}
    }

}



sub genSetModePackets {
    my ($modenum, %mode) = @_;
    my @packetbytes;
    my $packetptr = 0;
    my @packetarray;

    # Quick error checks...
    if ($modenum < 1 || $modenum > 32) {
	return;
    }

    if (! $mode{rx_frequency}) {
	# modes have to at least have a receive freq
	return;
    }
    
    # See comments in getMode about this mode name field
    if ($mode{mode_name} && $mode{mode_name} != $modenum) {
	$packetbytes[$packetptr] = $mode{mode_name} + 0x80;
    } else {
	$packetbytes[$packetptr] = 0x2F;
    }
    $packetptr++;
    
    # Encode rx frequency steps as two bytes
    my $rxsteps = (($mode{rx_frequency} - $BASE_FREQUENCY) / $FREQUENCY_STEP) * 1000;
    $packetbytes[$packetptr] = ($rxsteps & 0xFF00) >> 8 ;
    $packetptr++;
    $packetbytes[$packetptr] = $rxsteps & 0x00FF;
    $packetptr++;

    # Same for tx frequency steps
    my $txsteps = (($mode{tx_frequency} - $BASE_FREQUENCY) / $FREQUENCY_STEP) * 1000;
    $packetbytes[$packetptr] = ($txsteps & 0xFF00) >> 8;
    $packetptr++;
    $packetbytes[$packetptr] = $txsteps & 0x00FF;
    $packetptr++;


    # To-do: This code does not properly clear the squelch fields,
    # if the user wants to get rid of them for a certain mode. 
    # Investigate.

    my $rxsquelchval = 0;
    if ($mode{rx_squelch_type} && $mode{rx_squelch_type} eq 'TPL') {
	# Encode Rx Squelch Value
	$rxsquelchval = $PL_CONSTANT / (10 * $mode{rx_squelch_val});
    }

    if ($mode{rx_squelch_type} eq 'DPL') {
	$rxsquelchval = $mode{rx_squelch_val};
    }

    $packetbytes[$packetptr] = ($rxsquelchval & 0xFF00) >> 8;
    $packetptr++;
    $packetbytes[$packetptr] = $rxsquelchval & 0x00FF;
    $packetptr++;

    my $txsquelchtype = 0;
    if ($mode{tx_squelch_type} eq 'TPL') {
	# Encode Tx Squelch Value
	$txsquelchval = $PL_CONSTANT / (20 * $mode{tx_squelch_val});
    }

    if ($mode{tx_squelch_type} eq 'DPL') {
	$txsquelchval = $mode{tx_squelch_val};
    }

    $packetbytes[$packetptr] = ($txsquelchval & 0xFF00) >> 8;
    $packetptr++;
    $packetbytes[$packetptr] = $txsquelchval & 0x00FF;
    $packetptr++;


    # Squelch types
    my $squelchbyte = 0;
    if ($mode{rx_squelch_type} eq 'TPL') {
	$squelchbyte |= 4;
    }
    if ($mode{rx_squelch_type} eq 'DPL') {
	$squelchbyte |= 8;
    }
    if ($mode{tx_squelch_type} eq 'TPL') {
	$squelchbyte |= 1;
    }
    if ($mode{tx_squelch_type} eq 'DPL') {
	$squelchbyte |= 2;
    }
    $packetbytes[$packetptr] = $squelchbyte;
    $packetptr++;

    # copy in the rest of the packet
    $packetbytes[$packetptr] = $mode{unknown_offset_10};
    $packetptr++;

    $packetbytes[$packetptr] = $mode{unknown_offset_11};
    $packetptr++;

    $packetbytes[$packetptr] = $mode{timeout};
    $packetptr++;

    $packetbytes[$packetptr] = ($mode{signaling_address} & 0xFF00) >> 8;
    $packetptr++;
    $packetbytes[$packetptr] = $mode{signaling_address} & 0x00FF;
    $packetptr++;

    $packetbytes[$packetptr] = $mode{unknown_offset_15};
    $packetptr++;

    $packetbytes[$packetptr] = $mode{unknown_offset_16};
    $packetptr++;

    $packetbytes[$packetptr] = $mode{unknown_offset_17};
    $packetptr++;

    $packetbytes[$packetptr] = ($mode{scan_list} & 0xFF00) >> 8;
    $packetptr++;
    $packetbytes[$packetptr] = $mode{scan_list} & 0x00FF;
    $packetptr++;

    my $checksum = &binaryChecksum(@packetbytes);
    $packetbytes[$packetptr] = $checksum;
    

    my $offset = $MODE_BASE_ADDRESS + (($modenum - 1) * 21);

    # We can only write to the radio is 8-byte chunks.
    # So break the byte stream into chunks of that size.
    $packetarray[0] = genPacket('write_data', 8, $offset, @packetbytes[0..7]);
    $packetarray[1] = genPacket('write_data', 8, $offset + 8, @packetbytes[8..15]);
    $packetarray[2] = genPacket('write_data', 5, $offset + 16, @packetbytes[16..20]);
    return @packetarray;
}


sub getMode {
    my $modenum = shift;
    my %mode; 

    if (($modenum - 1) < 0) {
	return;
    }

    if ($modenum > $MODE_COUNT) {
	return;
    }

    my $querypacket = &genQueryModePacket($modenum - 1);
    &transmit($querypacket);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
	# packet looks good; decode it
	$mode{mode_num} = $modenum;
	$mode{mode_name} = $packetarray[1]{bytes}[1];
	
	# If the mode name is 0x2F, then the mode name is the
	# same as the mode_num.  Otherwise, subtract 0x80 
	# from the mode_name to get the value to be displayed
	# on the two-digit display

	if ($mode{mode_name} == 0x2F) {
	    $mode{mode_name} = $modenum;
	} else {
	    $mode{mode_name} -= 0x80;
	}

	$mode{rx_frequency_offset} = $packetarray[1]{bytes}[2] << 8;
	$mode{rx_frequency_offset} += $packetarray[1]{bytes}[3];
	$mode{tx_frequency_offset} = $packetarray[1]{bytes}[4] << 8;
	$mode{tx_frequency_offset} += $packetarray[1]{bytes}[5];

	$mode{rx_frequency} = $BASE_FREQUENCY + ($mode{rx_frequency_offset} * 5) / 1000;
	if ($mode{tx_frequency_offset} == 0xFFFF) {
	    $mode{tx_frequency} = 0;
	} else {
	    $mode{tx_frequency} = $BASE_FREQUENCY + ($mode{tx_frequency_offset} * 5) / 1000;
	}

	$rxsquelchval = $packetarray[1]{bytes}[6] << 8;
	$rxsquelchval += $packetarray[1]{bytes}[7];

	$txsquelchval = $packetarray[1]{bytes}[8] << 8;
	$txsquelchval += $packetarray[1]{bytes}[9];

	$squelchtype = $packetarray[1]{bytes}[10];

	$mode{rx_squelch_type} = '';
	$mode{rx_squelch_val} = 0;
	$mode{tx_squelch_type} = '';
	$mode{tx_squelch_val} = 0;

	if ($squelchtype & 0x08) {
	    $mode{rx_squelch_type} = 'DPL';
	    $mode{rx_squelch_val} = $rxsquelchval;
	}

	if ($squelchtype & 0x04) {
	    $mode{rx_squelch_type} = 'TPL';
	    $mode{rx_squelch_val} = int ($PL_CONSTANT / $rxsquelchval) / 10;
	}

	if ($squelchtype & 0x02) {
	    $mode{tx_squelch_type} = 'DPL';
	    $mode{tx_squelch_val} = $txsquelchval;
	}

	if ($squelchtype & 0x01) {
	    $mode{tx_squelch_type} = 'TPL';
	    $mode{tx_squelch_val} = int ($PL_CONSTANT / (2 * $txsquelchval)) / 10;
	}

	$mode{unknown_offset_10} = $packetarray[1]{bytes}[11];
	$mode{unknown_offset_11} = $packetarray[1]{bytes}[12];
	$mode{timeout} = $packetarray[1]{bytes}[13];
	
	$mode{signaling_address} = $packetarray[1]{bytes}[14] << 8;
	$mode{signaling_address} += $packetarray[1]{bytes}[15];

	$mode{unknown_offset_15} = $packetarray[1]{bytes}[16];
	$mode{unknown_offset_16} = $packetarray[1]{bytes}[17];

	$mode{unknown_offset_17} = $packetarray[1]{bytes}[18];  # supposed to always be 0xFF
	
	$mode{scan_list} = $packetarray[1]{bytes}[19] << 8;
	$mode{scan_list} += $packetarray[1]{bytes}[20];

	$mode{checksum} = $packetarray[1]{bytes}[21];

    } else {
	$mode{error} = "BAD_RESPONSE ";
    }

    return %mode;
}	

  


sub getModeBaseAddress {
    my $base_address = 0xB68D;
    
    # Radios with > 16 modes cannot fit their codeplugs into 
    # onboard EEPROM.  So the firmware moves them to a higher
    # address on the external (socketed) EEPROM.  We need 
    # to check this first to see where to look for mode data.

    my $ext_mode_address = 0xB624;
    my $packet = &genPacket("request_data", 2, $ext_mode_address, ());
    &transmit($packet);
    my $recvbuf = &receive();
    my @packetarray = &parsePacketStream($recvbuf);
    if ($packetarray[1]{lead_in} eq 'radio' && $packetarray[1]{function_code} == 0x38) {
	my $moved_address = $packetarray[1]{bytes}[1] << 8;
	$moved_address += $packetarray[1]{bytes}[2];
	if ($moved_address >= 0x6000 && $moved_address <= 0x7FFF) {
	    $base_address = $moved_address;
	}
    }

    # $base_address is now set correctly regardless of whether the mode data
    # is in base EEPROM or extended.  

    return $base_address;
}



sub genQueryModePacket {
    my $mode = shift;
    my $base_address = 0xB68D;
    my $mode_size = 21;
    my $offset;


    $offset = $MODE_BASE_ADDRESS + $mode_size * $mode;

    return &genPacket("request_data", $mode_size, $offset, ());
}


	
    
sub genQuerySerialNumberPacket {
    my $base_address = 0xB613;

    return &genPacket("request_data", 10, $base_address, ());
}



sub genResetPacket {
    return &genPacket("reset", 0, 0x0000, ());
}


sub genHighSpeedPacket {
    return &genPacket("high_speed", 1, 0x0000, 0x04);
}

sub genPacket {
    # packet format is...
    #
    # byte 0: 0x04  (means sent by RSS host)
    # byte 1: null byte, high nybble, with 0x30 added to it
    # byte 2: null byte, low nybble, with 0x30 added to it
    # byte 3: function code, high nybble, with 0x30 added to it
    # byte 4: function code, low nybble, with 0x30 added to it
    # byte 5: byte count, high nybble with 0x30 added
    # byte 6: byte count, low nybble with 0x30 added
    # byte 7: address high, high nybble with 0x30 added
    # byte 8: address high, low nybble with 0x30 added
    # byte 9: address low, high nybble with 0x30 added
    # byte 10: address low, low nybble with 0x30 added
    # bytes 11 - 26: data bytes, expanded into nybbles and 0x30 added
    # (n-1)th byte: checksum high nybble with 0x30 added
    # nth byte: checksum low nybble with 0x30 added
    #
    # The "0x30 added to it" business is RSS' way of turning
    # nybbles into ASCII characters.  Necessary because of
    # the seven bit serial encoding.

    my $functioncode = shift;
    my $bytecount = shift;
    my $address = shift;    # Note that this is a 16-bit address
    my @bytes = @_;
    my $packet;
    my @rawbytes;

    # The very first byte of a computer generated packet contains 0x04.
    # But we won't put this value into rawbytes, because it is
    # not computed in the checksum and thus will get in the way.

    # first byte is always null
    push @rawbytes, 0x00;

    switch ($functioncode) {
	case 'connection_check' {
	    push @rawbytes, 0x21;
	}

	case 'high_speed' {
	    push @rawbytes, 0x2E;
	}

	case 'reset' {
	    push @rawbytes, 0x23;
	}

	case 'request_data' {
	    push @rawbytes, 0x79;
	}

	case 'write_data' {
	    push @rawbytes, 0x59;
	}
	
    }

    # The actual bytes to be sent in the packet need to 
    # be preceded by a null byte, and this is counted 
    # in the byte count.  The outer calling code
    # doesn't know about this little detail, so we
    # take care of it here.
    if ($bytecount) {
	push @rawbytes, $bytecount + 1;
    } else {
	push @rawbytes, 0;
    }

    # $address comes in as a 16-bit quantity.  Break it into
    # bytes, then run each byte through the nybble->ascii encoding.
    my $addresshigh = ($address & 0xFF00) >> 8;
    my $addresslow = $address & 0x00FF;
    push @rawbytes, $addresshigh;
    push @rawbytes, $addresslow;


    # Add in that silly null byte to the byte data stream.
    # But not if the function code is 'request_data'.
    if ($bytecount && $functioncode ne 'request_data') {
	push @rawbytes, 0;
    } 

    foreach (my $i = 0; $i <= $#bytes; $i++) {
	push @rawbytes, $bytes[$i];

    }

    my $crc = &binaryChecksum(@rawbytes);

    push @rawbytes, $crc;

    my @encodedbytes = encode(@rawbytes);

    # Remember that @rawbytes is missing the lead-in character 0x04.
    # But $packet needs it.

    $packet = pack("c" . ($#encodedbytes + 2),
		   0x04,
		   @encodedbytes);


    return $packet;
}


sub parsePacketStream {
    my $rawbytes = shift;

    # Parse a raw data stream from the radio into an array of
    # packets, with each packet stored as a hash.  

    my @packetarray;
    my $source;
    my $null_hi;
    my $null_lo;
    my $null;
    my $functioncode_hi;
    my $functioncode_lo;
    my $functioncode;
    my $bytecount_hi;
    my $bytecount_lo;
    my $bytecount;
    my $addresshigh_hi;
    my $addresshigh_lo;
    my $addresshigh;
    my $addresslow_hi;
    my $addresslow_lo;
    my $addresslow;
    my $crc_hi;
    my $crc_lo;
    my $crc;
    my $byte_hi;
    my $byte_lo;
    my $byte;
    my @checksumarray;
    my $checksum;

    my $ptr = 0;  # our index into the bytestream
    my $packetptr = 0;  # our count of packets found in the stream
    my $i;

    while($ptr < length($rawbytes)) {
	# Store the original byte stream in the data structure
	# for debugging purposes.
	$packetarray[$packetptr]{raw_bytes} = $rawbytes;

 
	$source = unpack("c", substr($rawbytes, $ptr, 1));
	if ($source && $source == 0x04) {
	    $packetarray[$packetptr]{lead_in} = "host";
	} elsif ($source && $source == 0x1c) {
	    $packetarray[$packetptr]{lead_in} = "radio";
	} else {
	    $packetarray[$packetptr]{error} .= "BAD_LEAD-IN_BYTE ";
	}

	$ptr++;
	($null_hi, $null_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$null = decode($null_hi, $null_lo);
	if ($null != 0x00) {
	    $packetarray[$packetptr]{error} .= "EXPECTED_NULL_BYTE_NOT_FOUND ";
	}

	$ptr += 2;
	($functioncode_hi, $functioncode_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$functioncode = decode($functioncode_hi, $functioncode_lo);
	$packetarray[$packetptr]{function_code} = $functioncode;

	$ptr += 2;
	($bytecount_hi, $bytecount_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$bytecount = decode($bytecount_hi, $bytecount_lo);
	$packetarray[$packetptr]{byte_count} = $bytecount;

	$ptr += 2;
	($addresshigh_hi, $addresshigh_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$addresshigh = decode($addresshigh_hi, $addresshigh_lo);
	$packetarray[$packetptr]{address_high} = $addresshigh;

	$ptr += 2;
	($addresslow_hi, $addresslow_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$addresslow = decode($addresslow_hi, $addresslow_lo);
	$packetarray[$packetptr]{address_low} = $addresslow;
	
	$ptr += 2;
	# Suck in the remaining bytes.
	if ($packetarray[$packetptr]{lead_in} eq 'host' && $packetarray[$packetptr]{function_code} == 0x79 ) {
	    # do nothing?
	} else {
	    for ($i = 0; $i < $bytecount; $i++) {
		($byte_hi, $byte_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
		$byte = decode($byte_hi, $byte_lo);
		if ($byte > 255) {
		    # it can't be, based on the protocol, so we must
		    # be screwed up
		    $packetarray[$packetptr]{error} .= "BYTE_AT_INDEX_" . $i . "_FROM_CHARS_" . chr($byte_hi) ."," . chr($byte_lo) . "_OUT_OF_BOUNDS ";
		    $packetarray[$packetptr]{bytes}[$i] = 0;
		} else {
		    $packetarray[$packetptr]{bytes}[$i]= $byte;
		    if ($i > 0) {
			# the zeroth byte is always null, so skip it
			# in our chars string...
			$packetarray[$packetptr]{chars} .= chr($byte);
		    }
		}
		$ptr += 2;
	    }
	}

	($crc_hi, $crc_lo) = unpack("c2", substr($rawbytes, $ptr, 2));
	$crc = decode($crc_hi, $crc_lo);
	$packetarray[$packetptr]{checksum} = $crc;

	$ptr += 2;

	# verify checksum...
	@checksumarray = ($functioncode, $bytecount, $addresshigh, $addresslow);
	for ($i = 0; $i < $bytecount; $i++) {
	    push (@checksumarray, $packetarray[$packetptr]{bytes}[$i]);
	}
	$checksum = &binaryChecksum(@checksumarray);
	if ($checksum != $crc) {
	    $packetarray[$packetptr]{error} .= "BAD_CHECKSUM ";
	}

	$packetptr++;
    }
	
    return @packetarray;
}


sub binaryChecksum {
    my @bytes = @_;
    my $byte;
    my $sum = 0;

    for (my $i = 0; $i <= $#bytes; $i++) {
	$byte = $bytes[$i];
	if ($byte) {
	    $byte &= 0xFF;
	    $sum += $byte;
	}
    }
    
    my $checksum = (-$sum) & 0xFF;
    return $checksum;

}


sub verifyConnectionStatus{
    my $buf = shift;

    my($leadin, 
       $nullbyte_hi, 
       $nullbyte_lo, 
       $functioncode_hi, 
       $functioncode_lo, 
       $bytecount_hi, 
       $bytecount_lo,
       $remaining) = unpack("c7 c*", $buf);

    my $functioncode = &decode($functioncode_hi, $functioncode_lo);

    if ($leadin == 0x1c && $functioncode == 0x24) {
	return 1;
    } else {
	return 0;
    }
}


sub encode {
    my @bytes = @_;
    my @encodedbytes;

    foreach (my $i = 0; $i <= $#bytes; $i++) {
	push @encodedbytes, &encodeHigh($bytes[$i]);
	push @encodedbytes, &encodeLow($bytes[$i]);
    }

    return @encodedbytes;
}



sub encodeHigh {
    my $byte = shift;

    my $nybble = ($byte & 0x00F0) >> 4;
    $nybble += 0x30;

    return $nybble;
}

sub encodeLow {
    my $byte = shift;

    my $nybble = $byte & 0x000F;
    $nybble += 0x30;

    return $nybble;
}


sub decode {
    my $hi = shift;
    my $lo = shift;
    
    $hi -= 0x30;
    $lo -= 0x30;
    $decoded_byte = $hi << 4;
    $decoded_byte += $lo;
    return $decoded_byte;
}



sub consoleLog {
    my $printstr = shift;

    print $printstr;

}
