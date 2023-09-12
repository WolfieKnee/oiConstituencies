#!/usr/bin/perl

use lib "./../lib/";	# Custom functions
use Data::Dumper;
use JSON::XS;
use YAML::XS;
use OpenInnovations::GeoJSON;

my %colours = (
	'black'=>"\033[0;30m",
	'red'=>"\033[0;31m",
	'green'=>"\033[0;32m",
	'yellow'=>"\033[0;33m",
	'blue'=>"\033[0;34m",
	'magenta'=>"\033[0;35m",
	'cyan'=>"\033[0;36m",
	'white'=>"\033[0;37m",
	'none'=>"\033[0m"
);

$types = {};
$connections = {};
$key = "PCON22CD";

# Load in the GeoJSON structure and work out bounding boxes for each feature
$geo = OpenInnovations::GeoJSON->new('file'=>"../../src/_data/geojson/constituencies-2022.geojson");

$n = @{$geo->{'features'}};
for($f = 0; $f < $n ; $f++){
	$area = $geo->{'features'}[$f]{'properties'}{$key};
	if(!$connections->{$area}){ $connections->{$area} = {'total'=>0,'slow'=>0,'fast'=>0,'rapid'=>0,'ultra'=>0}; }
	
}

# Load in the population figures
@data = LoadCSV("../../raw-data/Population.csv");
$ages = {};
for($i = 0; $i < @data; $i++){
	#Age group,ONSConstID,ConstituencyName,RegionID,RegionName,CountryID,CountryName,DateThisUpdate,DateOfDataset,Date,Const%,ConstLevel,Reg%,UK%
	#0-9,E14000554,Berwick-upon-Tweed,E12000001,North East,K02000001,UK,16/09/2021,30/06/2020,2020,8.20%,6183,10.90%,11.80%
	$cid = $data[$i]->{'ONSConstID'};
	if(!$ages->{$cid}){ $ages->{$cid} = 0; }
	if($data[$i]->{'Date'} eq "2020" && $data[$i]->{'Age group'} ne "0-9" && $data[$i]->{'Age group'} ne "10-19"){ $ages->{$cid} += $data[$i]->{'ConstLevel'}; }
	if($data[$i]->{'Date'} eq "2020"){ $ages->{$cid} += $data[$i]->{'ConstLevel'}; }
}



# Load the CSV into rows
# Comes from https://chargepoints.dft.gov.uk/api/retrieve/registry/format/csv
@rows = LoadCSV("../../raw-data/national-charge-point-registry.csv");
$n = @rows;
$bad = 0;
$badconnections = 0;

for($i = 0; $i < $n ; $i++){
	$lat = $rows[$i]->{'latitude'};
	$lon = $rows[$i]->{'longitude'};
	$area = $geo->findPoint($key,$lat,$lon);
	if($area){
	
		for($j = 1; $j <= 8; $j++){
			# Only include connections that are "In service"
			if($rows[$i]->{'connector'.$j.'Status'} eq "In service"){
				$typ = $rows[$i]->{'connector'.$j.'RatedOutputKW'};
				$rating = "";
				if($typ >= 3 && $typ <= 6){ $rating = "slow"; }
				if($typ >= 7 && $typ <= 22){ $rating = "fast"; }
				if($typ >= 25 && $typ <= 100){ $rating = "rapid"; }
				if($typ > 100){ $rating = "ultra"; }

				if($rating){
					if(!$types->{$rating}){ $types->{$rating} = 0; }
					$types->{$rating}++;
					if(!$connections->{$area}{$rating}){ $connections->{$area}{$rating} = 0; }
					$connections->{$area}{$rating}++;
				}else{
					warning("\tNo rating for $typ\n");
				}
				$connections->{$area}{'total'}++;
			}
		}
	}else{
		warning("\tCould not find enclosing area for $lat,$lon\n");
		$bad++;
		
		for($j = 1; $j <= 8; $j++){
			# Only include connections that are "In service"
			if($rows[$i]->{'connector'.$j.'Status'} eq "In service"){
				$badconnections++;
			}
		}
	}
}
open(FILE,">","../../src/_data/sources/transport/national_charge_point_registry_by_constituency.csv");
print FILE "$key,all";
print FILE ",slow (3-6 KW),fast (7-22 KW),rapid (25-100 KW),ultra (>100 KW),population (2020)";
print FILE ",all (per 100k),slow (3-6 KW per 100k),fast (7-22 KW per 100k),rapid (25-100 KW per 100k),ultra (>100 KW per 100k)";
print FILE "\n";
foreach $area (sort(keys(%{$connections}))){
	print FILE ($area =~ /,/ ? "\"$area\"": $area);
	print FILE ",$connections->{$area}{'total'},$connections->{$area}{'slow'},$connections->{$area}{'fast'},$connections->{$area}{'rapid'},$connections->{$area}{'ultra'},$ages->{$area}";
	print FILE ",".sprintf("%0d",1e5*$connections->{$area}{'total'}/$ages->{$area}).",".sprintf("%0d",1e5*$connections->{$area}{'slow'}/$ages->{$area}).",".sprintf("%0d",1e5*$connections->{$area}{'fast'}/$ages->{$area}).",".sprintf("%0d",1e5*$connections->{$area}{'rapid'}/$ages->{$area}).",".sprintf("%0d",1e5*$connections->{$area}{'ultra'}/$ages->{$area});
	print FILE "\n";
}
close(FILE);
print "$bad unidentified chargepoint locations ($badconnections chargepoints)\n";



################
# Subroutines

sub msg {
	my $str = $_[0];
	my $dest = $_[1]||STDOUT;
	foreach my $c (keys(%colours)){ $str =~ s/\< ?$c ?\>/$colours{$c}/g; }
	print $dest $str;
}

sub error {
	my $str = $_[0];
	$str =~ s/(^[\t\s]*)/$1<red>ERROR:<none> /;
	msg($str,STDERR);
}

sub warning {
	my $str = $_[0];
	$str =~ s/(^[\t\s]*)/$1$colours{'yellow'}WARNING:$colours{'none'} /;
	print STDERR $str;
}


sub LoadCSV {
	my $file = shift;
	my $col = shift;
	my $compact = shift;

	my (@lines,$str,@rows,@cols,@header,$r,$c,@features,$data,$key,$k,$f,$n,$n2);

	msg("Processing CSV from <cyan>$file<none>\n");
	open(FILE,"<:utf8",$file);
	@lines = <FILE>;
	close(FILE);
	$str = join("",@lines);

	$n = () = $str =~ /\r\n/g;
	$n2 = () = $str =~ /\n/g;
	if($n < $n2 * 0.25){ 
		# Replace CR LF with escaped newline
		$str =~ s/\r\n/\\n/g;
	}
	@rows = split(/[\n]/,$str);

	$n = @rows;
	
	for($r = 0; $r < @rows; $r++){
		@cols = split(/,(?=(?:[^\"]*\"[^\"]*\")*(?![^\"]*\"))/,$rows[$r]);
		if($r < 1){
			# Header
			if(!@header){
				@header = @cols;
			}else{
				for($c = 0; $c < @cols; $c++){
					$header[$c] .= "\n".$cols[$c];
				}
			}
		}else{
			$data = {};
			for($c = 0; $c < @cols; $c++){
				$cols[$c] =~ s/(^\"|\"$)//g;
				$data->{$header[$c]} = $cols[$c];
			}
			push(@features,$data);
		}
	}
	if($col){
		$data = {};
		for($r = 0; $r < @features; $r++){
			$f = $features[$r]->{$col};
			if($compact){ $f =~ s/ //g; }
			$data->{$f} = $features[$r];
		}
		return $data;
	}else{
		return @features;
	}
}
