package SCRAM::ScramProjectDB;
use Utilities::Verbose;
use Utilities::AddDir;
use File::Basename;
require 5.004;
@ISA=qw(Utilities::Verbose);

sub new()
{
  my $class=shift;
  my $self={};
  bless $self, $class;
  $self->{scramrc}='etc/scramrc';
  $self->{linkfile}='links.db';
  $self->{archs}={};
  $self->{listcache}= {};
  $ENV{SCRAM_LOOKUPDB}=&Utilities::AddDir::fixpath($ENV{SCRAM_LOOKUPDB});
  $self->_initDB();
  return $self;
}

sub getarea ()
{
  my $self=shift;
  my $name=shift;
  my $version=shift;
  my $arch = $ENV{SCRAM_ARCH};
  my $data = $self->_findProjects($name,$version,1,$arch);
  my $selarch=undef;
  if (scalar(@{$data->{$arch}}) == 1) { $selarch=$arch;}
  elsif ($main::FORCE_SCRAM_ARCH eq "")
  {
    $data = $self->updatearchs($name,$version,{$arch});
    my @archs = keys %{$data};
    if (scalar(@archs)==1){$selarch=$archs[0];}
    elsif(scalar(@archs)>1){$selarch=$self->productionArch($name,$version);}
  }
  my $area=undef;
  if ((defined $selarch) and (exists $data->{$selarch})){$area=$self->getAreaObject($data->{$selarch}[0], $selarch);}
  return $area;
}

sub productionArch()
{
  my ($self,$project,$version)=@_;
  my $module="SCRAM::Plugins::".uc($project);
  my $arch=undef;
  eval {
    eval "use $module";
    if($@) {return $arch;}
    my $tc=$module->new();
    my @archs=$tc->releaseArchs($version,1);
    if (scalar(@archs)==1){$arch=$archs[0];}
  };
  return $arch;
}

sub listlinks()
{
  my $self=shift;
  my $links={};
  $links->{local}=[]; $links->{linked}=[]; 
  my %local=();
  foreach my $d (@{$self->{LocalLinks}}){$local{$d}=1; push @{$links->{local}},$d;}
  my $cnt=scalar(@{$self->{DBS}{order}});
  for(my $i=1;$i<$cnt;$i++)
  {
    my $d=$self->{DBS}{order}[$i];
    if (!exists $local{$d}){push @{$links->{linked}},$d;}
  }
  return $links;
}

sub listall()
{
  my ($self,$proj,$ver,$valid,$all)=@_;
  my $xdata = $self->_findProjects($proj,$ver,undef,$ENV{SCRAM_ARCH},$valid);
  if ($all)
  {
    foreach my $arch (keys %{$self->{archs}})
    {
      if ($arch eq $ENV{SCRAM_ARCH}){next;}
      $xdata = $self->_findProjects($proj,$ver,undef,$arch,$valid,$xdata);
    }
  }
  return $xdata;
}

sub updatearchs()
{
  my ($self,$name,$version,$skiparch)=@_;
  $self->{listcache} = {};
  foreach my $arch (keys %{$self->{archs}})
  {
    if (exists $skiparch->{$arch}){next;}
    my $data = $self->_findProjects($name,$version,1,$arch);
    if (scalar(@{$data->{$arch}})==1){$self->{listcache}{$arch}=$data->{$arch};}
  }
  return $self->{listcache};
}

sub link()
{
  my ($self,$db)=@_;
  $db=~s/^\s*file://o; $db=~s/\s//go;
  if ($db eq ""){return 1;}
  $db=&Utilities::AddDir::fixpath($db);
  if ($db eq $ENV{SCRAM_LOOKUPDB}){return 1;}
  if (-d $db)
  {
    foreach my $d (@{$self->{LocalLinks}}){if ($db eq $d){return 0;}}
    push @{$self->{LocalLinks}},$db;
    $self->_save ();
    return 0;
  }
  return 1;
}

sub unlink()
{
  my ($self,$db)=@_;
  $db=~s/^\s*file://o; $db=~s/\s//go;
  if ($db eq ""){return 1;}
  $db=&Utilities::AddDir::fixpath($db);
  my $cnt=scalar(@{$self->{LocalLinks}});
  for(my $i=0;$i<$cnt;$i++)
  {
    if ($db eq $self->{LocalLinks}[$i])
    {
      for(my $j=$i+1;$j<$cnt;$j++){$self->{LocalLinks}[$j-1]=$self->{LocalLinks}[$j];}
      pop @{$self->{LocalLinks}};
      $self->_save ();
      return 0;
    }
  }
  return 1;
}

sub getAreaObject ()
{
  my ($self,$data,$arch)=@_;
  my $area=Configuration::ConfigArea->new($arch);
  my $loc = $data->[2];
  if ($area->bootstrapfromlocation($loc) == 1)
  {
    $area = undef;
    print STDERR "ERROR: Attempt to ressurect ",$data->[0]," ",$data->[1]," from $loc unsuccessful\n";
    print STDERR "ERROR: $loc does not look like a valid release area for SCRAM_ARCH $arch.\n";
  }
  return $area;
}

##################################################

sub _save ()
{
  my $self=shift;
  my $filename = $ENV{SCRAM_LOOKUPDB_WRITE}."/".$self->{scramrc};
  &Utilities::AddDir::adddir($filename);
  $filename.="/".$self->{linkfile};
  my $fh;
  if (!open ( $fh, ">$filename" )){die "Can not open file for writing: $filename\n";}
  foreach my $db (@{$self->{LocalLinks}}){if ($db ne ""){print $fh "$db\n";}}
  close($fh);
  my $mode=0644;
  chmod $mode,$filename;
}

sub _initDB ()
{
  my $self=shift;
  my $scramdb=shift;
  my $cache=shift || {};
  my $local=0;
  my $localdb=$ENV{SCRAM_LOOKUPDB};
  if (!defined $scramdb)
  {
    $scramdb=$localdb;
    $self->{DBS}{order}=[];
    $self->{DBS}{uniq}={};
    $self->{LocalLinks}=[];
    $local=1;
  }
  if (exists $self->{DBS}{uniq}{$scramdb}){return;}
  $self->{DBS}{uniq}{$scramdb}={};
  push @{$self->{DBS}{order}},$scramdb;
  my $db="${scramdb}/".$self->{scramrc};
  my $ref;
  foreach my $f (glob("${db}/*.map"))
  {
    if((-f $f) && (open($ref,$f)))
    {
      while(my $line=<$ref>)
      {
        chomp $line; $line=~s/\s//go;
        if ($line=~/^([^=]+)=(.+)$/o){$self->{DBS}{uniq}{$scramdb}{uc($1)}{$2}=1;}
      }
      close($ref);
    }
  }
  if (!$local)
  {
    foreach my $proj (keys %{$self->{DBS}{uniq}{$localdb}})
    {
      if (!exists $self->{DBS}{uniq}{$scramdb}{$proj})
      {
        foreach my $path (keys %{$self->{DBS}{uniq}{$localdb}{$proj}}){$self->{DBS}{uniq}{$scramdb}{$proj}{$path}=1;}
      }
    }
  }
  else
  {
    my $varch=$ENV{SCRAM_ARCH}; $varch=~s/_gcc\d+.*$//;
    foreach my $f (glob("${localdb}/${varch}_*/etc/default-scramv1-version"))
    {
      if ($f=~/^${localdb}\/([^\/]+)\/etc\/default-scramv1-version$/){$self->{archs}{$1}=1;}
    }
    if (! exists $self->{archs}{$ENV{SCRAM_ARCH}})
    {
      print STDERR "ERROR: SCRAM is not istalled for $ENV{SCRAM_ARCH} architecture on your site.\n";
    }
  }
  if(open($ref, "${db}/".$self->{linkfile}))
  {
    my %uniq=();
    while(my $line=<$ref>)
    {
      chomp $line; $line=~s/\s//go;
      if (($line eq "") || (!-d $line)){next;}
      $line=&Utilities::AddDir::fixpath($line);
      if (exists $uniq{$line}){next;}
      $uniq{$line}=1;
      $self->_initDB($line,$cache);
      if ($local){push @{$self->{LocalLinks}},$line;}
    }
    close($ref);
  }
}

sub _findProjects()
{
  my $self=shift;
  my $proj=shift || '.+';
  my $ver=shift || '.+';
  my $exact=shift  || undef;
  my $arch=shift || $ENV{SCRAM_ARCH};
  my $valid=shift || 0;
  my $xdata=shift || {};
  my %data=();
  my %uniq=();
  $xdata->{$arch} = [];
  if (!exists $self->{archs}{$arch}){return $xdata;}
  foreach my $base (@{$self->{DBS}{order}})
  {
    foreach my $p (keys %{$self->{DBS}{uniq}{$base}})
    {
      if ($p!~/^$proj$/){next;}
      my $db="${base}/".join(" ${base}/",keys %{$self->{DBS}{uniq}{$base}{$p}});
      $db=~s/\$(\{|\(|)SCRAM_ARCH(\}|\)|)/$arch/g;
      foreach my $fd (glob($db))
      {
        if (!-d $fd){next;}
	if (($valid) && (!-d "${fd}/.SCRAM/${arch}/timestamps/self")){next;}
	my $d=basename($fd);
	if ($d=~/^$ver$/)
	{
	  if ($exact){push @{$xdata->{$arch}}, [$p,$d,$fd]; return $xdata;}
	  elsif(!exists $uniq{"$p:$d"})
	  {
	    $uniq{"$p:$d"}=1;
	    my $m = (stat($fd))[9];
	    $data{$m}{$p}{$d}=$fd;
	  }
	}
      }
    }
  }
  foreach my $m (sort {$a <=> $b} keys %data)
  {
    foreach my $p (keys %{$data{$m}})
    {
      foreach my $v (keys %{$data{$m}{$p}})
      {
        push @{$xdata->{$arch}}, [$p,$v,$data{$m}{$p}{$v}];
      }
    }
  }
  return $xdata;
}
