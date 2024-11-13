#!/bin/bash
set -ex
set -o pipefail

## resolve folder of this script, following all symlinks,
## http://stackoverflow.com/questions/59895/can-a-bash-script-tell-what-directory-its-stored-in
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  LIBCQA_SCRIPT_DIR="$( cd -P "$( dirname "$SCRIPT_SOURCE" )" && pwd )"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$LIBCQA_SCRIPT_DIR/$SCRIPT_SOURCE"
done
readonly LIBCQA_SCRIPT_DIR="$( cd -P "$( dirname "$SCRIPT_SOURCE" )" && pwd )"

if [[ x${WORKSPACE} == x ]]; then
  export WORKSPACE=/mnt/workspace
fi

function parseArguments() {
  for a in "$@"
  do
    case $a in
      --jdk=*)
        ARG_JDK="${a#*=}"
      ;;
      --report-dir=*)
        ARG_REPORT_DIR="${a#*=}"
      ;;
      *)
        echo "Unrecognized argument: '$a'" >&2
        exit 1
      ;;
    esac
  done
}

function processArguments() {
  if [[ -z $ARG_JDK ]] ; then
    echo "JDK image was not specified" >&2
    exit 1
  # I am not 100% sure this is the best approach. It may be enough that the command does not fail without needing the exact return value.
  # I am running this to ensure the string passed in as the image repo actually exisits.
  elif [[ $(curl --silent -f -I -k $ARG_JDK |grep -E "^HTTP" | awk -F " " '{print $2}') == 302 ]]
  then
    echo "OpenJDK Container Image found on Brew."
    JDK_CONTAINER_IMAGE=$ARG_JDK 
  else
    echo "OpenJDK Container Image not found on Brew. Check that images exists."
    echo "Failed Image: $ARG_JDK"
    exit 1
  fi

  if [[ -z $ARG_REPORT_DIR ]] ; then
    echo "Report dir was not specified" >&2
    exit 1
  else
    readonly REPORT_DIR="$( readlink -m "$ARG_REPORT_DIR" )"
    mkdir -p "$REPORT_DIR"
  fi

  readonly REPORT_FILE="$REPORT_DIR/report.txt"
  readonly CONTAINERQA_PROPERTIES="$REPORT_DIR/../containerQa.properties"
}

function archiveMetadataFiles() {
  echo "Archive the Repository Metadata files."
  echo "Workspace folder is: ${WORKSPACE}"
  cp -r ${WORKSPACE}/rpms-metadata $REPORT_DIR/../rpms_metadata
}

function pretest() {
  SKIPPED="!skipped! s2i is linux on selcted platforms only for now !skipped!"
  SKIPPED2="!skipped! no local maven !skipped!"
  SKIPPED3="!skipped! broken right now !skipped!"
  SKIPPED4="!skipped! jre only testing does not support this feature."
  SKIPPED5="!skipped! reproducers security now must be enabled by OTOOL_RUN_SECURITY_REPRODUCERS=true"
  SKIPPED6="!skipped! rhel 7 based images do not support this functionality."
  SKIPPED7="!skipped! rhel 7 Os version of Podman does not support this functionality."
  SKIPPED8="!skipped! rhel 8 Os version of Podman automatically sets containers to FIPS."
  SKIPPED9="!skipped! no need to disable FIPS, when it is not already there."
  export DISPLAY=:0
  if [ "x$OTOOL_CONTAINER_RUNTIME" = "x" ] ; then
    export PD_PROVIDER=podman
  else
    export PD_PROVIDER=$OTOOL_CONTAINER_RUNTIME
  fi
}

function setup() {
  pretest
  getHashFromImageId
}

# With the addition of a JRE Runtime container we should not run for full jdk features like
# Maven, S2i, Javac.
function skipIfJreExecution() {
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
      echo "$SKIPPED4"
    exit
  fi
}

# Use this flag to skip tests when executing on a Rhel 7 host. In some cases backend container
# functionality the tests are looking for is not available in that version.
function skipIfRhel7Execution() {
  if [ "$OTOOL_BUILD_OS" == "el.7z"  ] ; then
      echo "$SKIPPED6"
    exit
  fi
}

function skipIfRhel7OsExecution() {
  if [ "$OTOOL_OS" == "el.7z"  ] ; then
      echo "$SKIPPED7"
    exit
  fi
}

function skipIfRhel8FipsExecution() {
  if [ "$OTOOL_OS_NAME" == "el"  ] && [ "$OTOOL_OS_VERSION" == "8" ] && [ "$OTOOL_cryptosetup" == "fips" ] ; then
      echo "$SKIPPED8"
    exit
  fi
}

function skipIfFipsExecution() {
  if [ "$OTOOL_cryptosetup" != "fips" ] ; then
      echo "$SKIPPED9"
    exit
  fi
}

## setUser: Check which OS version of container we are testing. Based on this, assign
##          the user for validation and further testing (s2i builds).
function setUser() {
  if [ ! "x$OVERWRITE_USER" == x ] ; then
    export USERNAME="$OVERWRITE_USER"
    return
  fi
  if $PD_PROVIDER inspect $HASH --format "{{.Labels.name}}" | grep -e 'ubi9'  ; then
      export USERNAME='default'
  else
      export USERNAME='jboss'
  fi
  echo "Username to test is: $USERNAME."
}

function podmanVersion() {
  $PD_PROVIDER --version
}

function cleanRuntimeImages() {
  set +e
   $PD_PROVIDER rmi -af
  set -e
}

function cleanContainerQaPropertiesFile() {
  true > $CONTAINERQA_PROPERTIES
}

function getHashFromImageId() {
  HASH=`$PD_PROVIDER inspect $JDK_CONTAINER_IMAGE --format "{{.Id}}"`
  echo "The Image under test's ID is: $HASH"
}

function pullImage() {
   $PD_PROVIDER pull $JDK_CONTAINER_IMAGE
}

function checkImage() {
   skipIfRhel7OsExecution
   IMG_DIGEST=`$PD_PROVIDER inspect $HASH --format "{{.Digest}}"`
   SOURCE_OF_TRUTH=`basename $TEST_DIGEST |sed "s/.*@//"`

   test $IMG_DIGEST = $SOURCE_OF_TRUTH
}

function buildFileWithHash() {
  grep -e $HASH $1
  $PD_PROVIDER build -f $1
}

function runOnBaseDir() {
  $PD_PROVIDER run -i $HASH "$@"
}

function runOnBaseDirOtherUser() {
  $PD_PROVIDER run -i -u 12324 $HASH "$@"
}

function runOnBaseDirBash() {
  $PD_PROVIDER run -i $HASH bash -c "$1"
}

function runOnBaseDirBashOtherUser() {
  $PD_PROVIDER run -i -u 12324 $HASH bash -c "$1"
}

function runOnBaseDirBashRootUser() {
  $PD_PROVIDER run -i -u root $HASH bash -c "$1"
}

function lsLUsrLibJvm() {
  runOnBaseDir  ls -l /usr/lib/jvm
}

function duItemsInUsrLibJvm() {
  runOnBaseDirBash "for x in \$(find  /usr/lib/jvm/  -maxdepth 1 -mindepth 1); do  du -s \$x ; done"
}

function duLItemsInUsrLibJvm() {
  runOnBaseDirBash "for x in \$(find  /usr/lib/jvm/  -maxdepth 1 -mindepth 1); do  du -sL \$x ; done"
}

function lsUsrLibJvm() {
  runOnBaseDir  ls -1 /usr/lib/jvm
}

function findRealFilesInUsrLibJvm() {
  skipIfJreExecution
  runOnBaseDir  find /usr/lib/jvm -type f
}

function imgOs() {
  runOnBaseDir  cat /etc/redhat-release
}

function imgHost() {
  runOnBaseDir uname -a # its an host!-)
}

function alternativesJava() {
  runOnBaseDir  alternatives --display java
}

function alternativesJavac() {
  skipIfJreExecution
  runOnBaseDir  alternatives --display javac
}

function javaVer() {
  runOnBaseDir  java -version
}

function javacVer() {
  skipIfJreExecution
  runOnBaseDir  javac -version
}

function whoAmI() {
  runOnBaseDir  whoami
}

function rpmQa() {
  runOnBaseDir   rpm -qa
}

function rpmQaSelected() {
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
      echo "JRE Runtime Check for selected rpms"
      runOnBaseDir   rpm -qa | grep -e fribidi -e sqlite -e libarchive -e java- -e dotnet
  else
      echo "Full OpenJDK Check for selected rpms"
      runOnBaseDir   rpm -qa | grep -e fribidi -e sqlite -e libarchive -e prometheus -e snakeyaml -e java- -e dotnet
  fi  
  
}

function getOldLog() {
  ls $(dirname $(dirname $REPORT_FILE))/$1*/report.txt
}

function getOsOldLog() {
  getOldLog 010_os.sh
}

function getImageMajorFromOldLog() {
  cat `getOsOldLog` | grep -v -e "^+"  | sed "s/\..*//g" | sed "s/[^0-9]\+//g"
 }

function getImageOsFromOldLog() {
  if cat `getOsOldLog` | grep -v -e "^+"  | grep -iq Fedora ; then
    echo "fedora"
  else
    echo "rhel"
  fi
}

function shouldBeCollection() {
  if [ `getImageOsFromOldLog` = "rhel" -a `getImageMajorFromOldLog` -eq "7" ] ; then
    echo "yes"
  else
    echo "no"
  fi
}

function getMavenVersion() {
  runOnBaseDir ls -l /etc/scl/conf/
  runOnBaseDir ls /etc/scl/conf/
}

function mavenCollectionVersion() {
  if [ `shouldBeCollection` == yes ] ; then
    getMavenVersion
  else
    echo "no_maven_collection"
  fi
}

function getMavenVersionOldLog() {
  getOldLog 030_mavenCollectionVersion.sh
}

# https://issues.redhat.com/browse/OPENJDK-921
# Confirm the images do not include the depricated Maven repo
function checkMavenRepoDefaults() {
  skipIfRhel7Execution  # No plan to change the rhel 7 images.

  # For the jre images, ensure there is no ~/.m2/settings.xml file
  # For the jdk images, ensure there is no repo maven.repository.redhat.com/techpreview/all
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
    runOnBaseDir [ ! -f .m2/settings.xml ]
  else  #JDK
    [[ `runOnBaseDir cat .m2/settings.xml` != *maven.repository.redhat.com/techpreview/all* ]]
  fi
}

function frontTrim() {
 sed "s/^\s\+//g"
}

function superTrim() {
 sed ':a;N;$!ba;s/\n/ /g' | sed "s/\\s//g"
}

function cleanBashOutputs() {
  grep -v -e "^+"  -e "^-" -e "^total"
}

function getMavenVersionFromOldLog() {
  cat `getMavenVersionOldLog` | grep -v -e "^+"  | tail -n 1 | superTrim
 }

function sclEnable() {
  echo " scl enable `getMavenVersionFromOldLog` -- "
}

function mavenJavaVersion() {
  skipIfJreExecution
  if [ `shouldBeCollection` == yes ] ; then
    runOnBaseDir `sclEnable` mvn --version
  else
    runOnBaseDir mvn --version
  fi
}

function mavenCreateAndRun() {
  skipIfJreExecution
  if [ `shouldBeCollection` == yes ] ; then
    # collections dont like multiline
    runOnBaseDirBash "`sclEnable` mvn -B archetype:generate -DgroupId=org.test.rhimg  -DartifactId=rhimg -DarchetypeArtifactId=maven-archetype-quickstart -DarchetypeVersion=1.4 -DinteractiveMode=false && cd rhimg && `sclEnable` mvn -B clean install && `sclEnable` java -cp  target/rhimg-1.0-SNAPSHOT.jar org.test.rhimg.App"
  else
    runOnBaseDirBash "mvn -B archetype:generate -DgroupId=org.test.rhimg  -DartifactId=rhimg -DarchetypeArtifactId=maven-archetype-quickstart -DarchetypeVersion=1.4 -DinteractiveMode=false &&  cd rhimg && sed -i 's;<maven.compiler.source>1.7</maven.compiler.source>;<maven.compiler.source>1.8</maven.compiler.source>;g' pom.xml && sed -i 's;<maven.compiler.target>1.7</maven.compiler.target>;<maven.compiler.target>1.8</maven.compiler.target>;g' pom.xml && mvn -B clean install && java -cp  target/rhimg-1.0-SNAPSHOT.jar org.test.rhimg.App"
  fi
}

function javacAndJavaAndTmp() {
  skipIfJreExecution
  code=`cat $LIBCQA_SCRIPT_DIR/HelloWorld.java`
  runOnBaseDirBash "echo \"$code\" > /tmp/HelloWorld.java && javac -d /tmp  /tmp/HelloWorld.java  && java -cp /tmp  HelloWorld"
}

function javacAndJavaAndTmpOtherUser() {
  skipIfJreExecution
  code=`cat $LIBCQA_SCRIPT_DIR/HelloWorld.java`
  runOnBaseDirBashOtherUser "echo \"$code\" > /tmp/HelloWorld.java && javac -d /tmp  /tmp/HelloWorld.java  && java -cp /tmp  HelloWorld"
}

function onlyOneCollection() {
  if [ `shouldBeCollection` == yes ] ; then
    cat $(getMavenVersionOldLog) | cleanBashOutputs
    a=$(cat $(getMavenVersionOldLog) | cleanBashOutputs| wc -l)
    test $a -eq 1
  fi
}

function readlinkJava() {
  runOnBaseDir  readlink -f /usr/bin/java
}

function readlinkJavac() {
  runOnBaseDir  readlink -f /usr/bin/javac
}

function getOldLsLog() {
  getOldLog 011_lsUsrLibJvm.sh
}

function getOldLsLLog() {
  getOldLog 012_lsLUsrLibJvm.sh
}

function getOldWhoAmILog() {
  getOldLog 015_whoAmI.sh
}

function getOldJavaVersionLog() {
  getOldLog 018_javaVersion.sh
}

function onlyOneJdk() {
  cat $(getOldLsLog) | cleanBashOutputs | grep java
  cat $(getOldLsLog) | cleanBashOutputs | grep jre
  javas=$(cat $(getOldLsLog) | cleanBashOutputs | grep java |wc -l)
  jres=$(cat $(getOldLsLog) | cleanBashOutputs | grep jre  |wc -l)
  #branch for jre vs jdk
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
    echo "otool jresdk settings is: $OTOOL_jresdk"
    # it is interval due to rhel 7/8 diffs
    test $javas -ge 1 -a $javas -le 1
    test $jres  -ge 5 -a $jres  -le 6
  else # JDK
    # it is interval due to rhel 7/8 diffs
    test $javas -ge 5 -a $javas -le 6
    test $jres  -ge 5 -a $jres  -le 6
  fi
}

function allExeptOneAreLinks() {
  cat $(getOldLsLLog) | cleanBashOutputs| grep java | grep -e "->"
  cat $(getOldLsLLog) | cleanBashOutputs| grep  jre | grep -e "->"
  javasLinks=$(cat $(getOldLsLLog) | cleanBashOutputs| grep java | grep -e "->" | wc -l)
  jresLinks=$(cat $(getOldLsLLog) | cleanBashOutputs| grep  jre | grep -e "->" | wc -l)

  if [ "$OTOOL_jresdk" == "jre"  ] ; then
    echo "otool jresdk settings is: $OTOOL_jresdk"
    # it is interval due to rhel 7/8 diffs
    test $javasLinks -ge 1 -a $javasLinks -le 1
    test $jresLinks  -ge 5 -a $jresLinks  -le 6
  else # JDK
    # it is interval due to rhel 7/8 diffs
    test $javasLinks -ge 4 -a $javasLinks -le 5
    test $jresLinks  -ge 5 -a $jresLinks  -le 6
  fi  

  cat $(getOldLsLLog) | cleanBashOutputs| grep java | grep -v -e "->"
  cat $(getOldLsLLog) | cleanBashOutputs| grep  jre | grep -v -e "->" || echo "no jre dir is ok" #  jres are ok to not exists
  javasNonLinks=$(cat $(getOldLsLLog) | cleanBashOutputs| grep java | grep -v -e "->" | wc -l)
  jresNonLinks=$(cat $(getOldLsLLog) | cleanBashOutputs| grep  jre | grep -v -e "->" | wc -l || true)
  nonLinks=$(($javasNonLinks + $jresNonLinks))
  # it is 1, bug in jdk11, empty dir of jdk8 
  test $nonLinks -eq 1 -o $nonLinks -eq 2

}

function testUsername() {
  setUser
  cat $(getOldWhoAmILog) | grep -v -e "^+"  -e "^-" -e "Emulate Docker.*" | superTrim
  a=$(cat $(getOldWhoAmILog) | grep -v -e "^+"  -e "^-" -e "Emulate Docker.*" | superTrim)
  test $a == $USERNAME
}

function getOldMvnVersionLog() {
  getOldLog 031_mavenJavaVersion.sh
}

function getOldReadLinkJavaLog() {
  getOldLog 020_readLinkJava.sh
}

function getOldReadLinkJavacLog() {
  getOldLog 021_readLinkJavac.sh
}

function getOldJavaSlavesJavaLog() {
  getOldLog 013_alternativesJava.sh
}

function getOldJavacSlavesJavacLog() {
  getOldLog 014_alternativesJavac.sh
}

function getOldPullLog() {
  getOldLog 001_prepareDocker.sh
}

# this also ensures, same jdk is used over jre/sdk
function mavenUsesCorrectJdk() {
  skipIfJreExecution
  mavenJava=`cat $(getOldMvnVersionLog) | tail -n 3 | head -n 1 | sed "s;.*: /;/;;" | sed "s;/jre;;" | superTrim `
  cat $(getOldReadLinkJavaLog)  | grep $mavenJava
  cat $(getOldReadLinkJavacLog) | grep $mavenJava
  cat $(getOldJavaSlavesJavaLog)   | grep $mavenJava
  cat $(getOldJavacSlavesJavacLog) | grep $mavenJava
  js=`cat $(getOldJavaSlavesJavaLog)   | grep $mavenJava | wc -l`
  cs=`cat $(getOldJavacSlavesJavacLog) | grep $mavenJava | wc -l`
  # jdk11 10, jdk8 14
  test $js -gt 5 -a $js  -lt 20 
  # jdk11 28, jdk8 34
  test $cs -gt 20 -a $cs -lt 45  
}

function getOsMajor() {
  cat $(getOsOldLog) | tail -n 1   | sed "s/\..*//g" | sed "s/[^0-9]\+//g"
}

function prepareS2I() {
  #todo each shell runs in individual instance, so this caching does not work!
  if [ ! "x$s2iBin" == "x" ] ; then
    echo "$s2iBin already created, continuing"
    return
  fi
  if [ `uname -m` == "x86_64" ] ; then
    local go="https://go.dev/dl/go1.22.3.linux-amd64.tar.gz"
  elif [ `uname -m` == "s390x" ] ; then
    local go="https://go.dev/dl/go1.22.3.linux-s390x.tar.gz"
  elif [ `uname -m` == "ppc64le" ] ; then
    local go="https://go.dev/dl/go1.22.3.linux-ppc64le.tar.gz"
  elif [ `uname -m` == "aarch64" ] ; then
    local go="https://go.dev/dl/go1.22.3.linux-arm64.tar.gz"
  else
    echo $SKIPPED
    s2iBin="undef"
    return
  fi
  echo "building s2iBin"
  local d=`mktemp -d`
  pushd $d
    wget $go
    tar -xf `basename $go`
    goPath="$PWD/go/bin"
    git clone "https://github.com/openshift/source-to-image.git"
    pushd source-to-image
      git checkout tags/v1.4.0
      PATH="$PATH:$goPath" make
      s2iBin=$(find $PWD/_output/local/bin/linux/ -type f)
    popd
  popd
}

function s2iLocal() {
  prepareS2I
  setUser
  if [ "x$s2iBin" == "xundef" -o "x$s2iBin" == "x" ] ; then
    echo $SKIPPED
    return
  fi
  local d=`mktemp -d`
  pushd $d
    DF=s2iDockerFile
    # branch needed here to allow for the added variables needed for a Jenkins Build. $JENKINS_BUILD will be 
    # defined in the calling function if it is attempting to build a Jenkins plug-in.
    if [[ "$JENKINS_BUILD" == "yes" ]] ; then
        # copy the jenkins settings file to the local tmp directory
        $s2iBin build -e "$MAIN" -e "$ARGS" -e "$SETTING_ARGS" "$REPO" "$HASH" "$NAME" --assemble-user $USERNAME --as-dockerfile $DF.orig
        cp $LIBCQA_SCRIPT_DIR/jenkins_settings.xml  upload/src
    else
        $s2iBin build -e "$MAIN" -e "$ARGS" "$REPO" "$HASH" "$NAME" --assemble-user $USERNAME --as-dockerfile $DF.orig
    fi
    if [ "x$OVERWRITE_USER" == x ] ; then
      #update the container file for proper functionality
      cat $DF.orig | sed "s;/usr/libexec;/usr/local;g" | sed "s;1001:0;$USERNAME:$USERNAME;g" | sed "s;/s2i/run;/s2i/run $ADDS;g;" > $DF.nw1
    else
      cat $DF.orig | sed "s;/s2i/run;/s2i/run $ADDS;g;" > $DF.nw1
    fi
    if [ "x$COMMIT_HASH" != x ] ; then
      #cd into the source folder and checkout the koji source based on the known commit
      pushd upload/src
         git checkout "$COMMIT_HASH"
      popd
    fi
    cat $DF.nw1 | tee $DF
    buildFileWithHash $DF
  popd
  rm -rf $d
}

function s2iBasic() {
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
      echo "otool jresdk settings is: $OTOOL_jresdk"
      echo "$SKIPPED4"
      return 
  fi  
  if which mvn ; then
    echo "maven found"
  else
    sudo yum install -y maven git || echo $SKIPPED2
    if which mvn ; then
      echo "maven installed"
    else
      return
    fi
  fi
  local d=`mktemp -d`
  pushd $d
    mvn -B archetype:generate -DgroupId=org.test.rhimg  -DartifactId=rhimg -DarchetypeArtifactId=maven-archetype-quickstart -DarchetypeVersion=1.4 -DinteractiveMode=false
    # Need to modify this generated pom file for a maven.compiler.source & target to be 1.8 rather than 1.7.
    pushd rhimg
       sed -i "s;<maven.compiler.source>1.7</maven.compiler.source>;<maven.compiler.source>1.8</maven.compiler.source>;g" pom.xml
       sed -i "s;<maven.compiler.target>1.7</maven.compiler.target>;<maven.compiler.target>1.8</maven.compiler.target>;g" pom.xml
       echo "Print the pom.xml file."
       cat pom.xml
    popd
    git config --global user.name "conatinerQa bot"
    git config --global user.email "ContBont@qa.com"
    git init --bare rhimgrepo
    git clone file://$d/rhimgrepo rhimgclone
    cp -vr rhimg/* rhimgclone
    pushd rhimgclone
      git add *
      git commit -m "initial commit"
      git push origin master
    popd
  popd
  MAIN="JAVA_MAIN_CLASS=org.test.rhimg.App"
  ARGS="Nothing=nowhere"
  REPO="file://$d/rhimgclone" 
  NAME="hello_world"
  ADDS=""
  s2iLocal
}

function s2iBinaryCopy() {
  prepareS2I
  setUser

  #$JDK_CONTAINER_IMAGE


  if [ "x$s2iBin" == "xundef" -o "x$s2iBin" == "x" ] ; then
    echo $SKIPPED
    return
  fi
  local d=`mktemp -d`
  pushd $d
    DF=s2iDockerFile

    $s2iBin build "$APP_SRC" "$BASEIMG" "$OUTIMG" --pull-policy never --context-dir=$CONTEXTDIR -r=${rev} \
                  --loglevel 1 --as-dockerfile $DF --image-scripts-url image:///usr/local/s2i

  buildFileWithHash $DF
  popd
  rm -rf $d
}

function s2iLocalDeps() {
  skipIfJreExecution
  MAIN="JAVA_MAIN_CLASS=org.judovana.calendarmaker.App"
  ARGS="MAVEN_ARGS=install -pl org.judovana.calendarmaker:CalendarMaker -am"
  REPO="https://github.com/judovana/CalendarMaker.git" 
  NAME="local_deps"
  ADDS="-- --save-wall=aaa.pdf -nowizard -noload -height=1000"
  s2iLocal
}

function s2iLocalDepsNoInstall() {
  skipIfJreExecution
  MAIN="JAVA_MAIN_CLASS=org.judovana.calendarmaker.App"
  ARGS="nothing=nowhere"
  REPO="https://github.com/judovana/CalendarMaker.git" 
  NAME="local_deps_noinst"
  ADDS="-- --save-wall=aaa.pdf -nowizard -noload -height=1000"
  s2iLocal
}


function s2iLocaMultiModWorksNoMain() {
  skipIfJreExecution
  MAIN="Nothing=nowhere"
  ARGS="MAVEN_ARGS=install -Dheadless -pl fake-koji:koji-scm -am"
  SETTING_ARGS="MAVEN_SETTINGS_XML=/tmp/src/jenkins_settings.xml"
  REPO="https://github.com/judovana/jenkins-scm-koji-plugin.git" 
  NAME="multimod_nomain"
  ADDS=""
  COMMIT_HASH="048d32f1a311ae97c87bd885dd17cac6dddb5f94"
  JENKINS_BUILD="yes"
  s2iLocal
}

function s2iLocaMultiModWorksMain() {
  skipIfJreExecution
  MAIN="JAVA_MAIN_CLASS=org.fakekoji.core.DummyMain"
  ARGS="MAVEN_ARGS=install -Dheadless -pl fake-koji:koji-scm -am"
  SETTING_ARGS="MAVEN_SETTINGS_XML=/tmp/src/jenkins_settings.xml"
  REPO="https://github.com/judovana/jenkins-scm-koji-plugin.git" 
  NAME="multimod_main"
  ADDS=""
  COMMIT_HASH="048d32f1a311ae97c87bd885dd17cac6dddb5f94"
  JENKINS_BUILD="yes"
  s2iLocal 
}

function s2iBinaryOnlyMode() {
  skipIfJreExecution
  APP_SRC="https://github.com/jboss-container-images/openjdk-test-applications"
  CONTEXTDIR="spring-boot-sample-simple/target" # trigger binary build
  rev="master"
  OUTIMG="s2i-out"
  BASEIMG="$HASH"
  s2iBinaryCopy
}

function getS2iLocalDepsBuildLog() {
  getOldLog 211_s2iLocaDepsWorks.sh
}

function getS2iLocalDepsNoInstallBuildLog() {
  getOldLog 214_s2iLocaDepsNoInstallWorks.sh
}


function getS2iLocaMultiModWorksNoMainLog() {
  getOldLog 212_s2iLocaMultiModWorksNoMain.sh
}

function getS2iLocaMultiModWorksMainLog() {
  getOldLog 213_s2iLocaMultiModWorksMain.sh
}

function getS2iLocaBasicLog() {
  getOldLog 410_s2iLocaBasic.sh
}

function runHashByPodman() {
  prepareS2I
  if [ "x$s2iBin" == "xundef" -o "x$s2iBin" == "x" ] ; then
    echo $SKIPPED
    return
  else
    $PD_PROVIDER run $1
  fi
}

function runS2iLocaBasic() {
  skipIfJreExecution
  local nwhash=`cat $(getS2iLocaBasicLog)  | tail -n 4 | head -n 1`
  runHashByPodman $nwhash
}

function runS2iLocaDeps() {
  skipIfJreExecution
  local nwhash=`cat $(getS2iLocalDepsBuildLog)  | tail -n 4 | head -n 1`
  runHashByPodman $nwhash
}

function checkHardcodedMaven() {
  skipIfJreExecution
  cat $(getOldMvnVersionLog)
  cat $(getOldMvnVersionLog) | grep "Apache Maven"
  if [ `getOsMajor` -eq 9 ] ; then
    cat $(getOldMvnVersionLog) | grep "Apache Maven 3.8"
  elif [ `getOsMajor` -eq 8 ] ; then
    cat $(getOldMvnVersionLog) | grep "Apache Maven 3.8"
  elif [ `getOsMajor` -eq 7 ] ; then
    cat $(getOldMvnVersionLog) | grep "Apache Maven 3.6"
  else
    cat $(getOldMvnVersionLog) | grep "Apache Maven 3."
  fi
}

function checkHardcodedJdks() {
  if [ "$OTOOL_jresdk" == "jre"  ] ; then
    echo "otool jresdk settings is: $OTOOL_jresdk"
    echo "Check version based off java -version call."
    JRE_8_VERSION='1.8.0_432-b06'
    JRE_11_VERSION='11.0.25+9-LTS'
    JRE_17_VERSION='17.0.13+11-LTS'
    JRE_21_VERSION='21.0.5'  #temp fix until the next cpu.
    cat $(getOldJavaVersionLog)
    cat $(getOldJavaVersionLog) | grep "openjdk version"
    cat $(getOldJavaVersionLog) | grep -e "$JRE_11_VERSION" -e "$JRE_8_VERSION" -e "$JRE_17_VERSION" -e "$JRE_21_VERSION"

  else
    cat $(getOldMvnVersionLog)
    cat $(getOldMvnVersionLog) | grep "Java version:"
    cat $(getOldMvnVersionLog) | grep -e "Java version: 11.0.25" -e "Java version: 1.8.0_432" -e "Java version: 17.0.13" -e "Java version: 21.0.5"
  fi    

}

function checkJdkMajorVersion() {
  # Otool provides the major version via ENV VAR 'OTOOL_JDK_VERSION'
  echo "Expected Major Version for Java is: $OTOOL_JDK_VERSION"
  if [[ $OTOOL_JDK_VERSION -eq 11 ]]; then
    VERSION_CHECK_KEY='openjdk version \"11.0'
  elif [[ $OTOOL_JDK_VERSION -eq 8 ]]; then
    VERSION_CHECK_KEY='openjdk version \"1.8'
  elif [[ $OTOOL_JDK_VERSION -eq 17 ]]; then
    VERSION_CHECK_KEY='openjdk version \"17.0'
  elif [[ $OTOOL_JDK_VERSION -eq 21 ]]; then
    VERSION_CHECK_KEY='openjdk version \"21.0'
  else
    echo "Environment variable 'OTOOL_JDK_VERSION' not accepted. Please Debug."
    VERSION_CHECK_KEY='-1'
    return -1
  fi

  cat $(getOldJavaVersionLog) | grep -e "$VERSION_CHECK_KEY"
}

#### Security-related checks ####

function lsalPasswd() {
  runOnBaseDir  ls -al /etc/passwd
}

function statPasswd() {
  runOnBaseDir  stat -c %u,%g,%a /etc/passwd
}

function getlsaletcpasswdOldLog() {
  getOldLog 006_reproducerOPENJDK-312_lsalpasswd.sh
}

function getStatetcpasswdOldLog() {
  getOldLog 006_reproducerOPENJDK-312_statpasswd.sh
}

function testGrpPasswd() {
  echo "Check group permissions on /etc/passwd file."

  a=$(cat $(getlsaletcpasswdOldLog)| tail -1 | cut -d ' ' -f 1)
  b=$(cat $(getStatetcpasswdOldLog)| tail -1 | superTrim)

  test $b = "0,0,644"
  test $a = "-rw-r--r--."
}

# Functions to record the container Image Size. Later the size will be evaluated to ensure
# limited increase in file size.

function convertToBytes() {
  # Convert given size into bytes.
  # Supported, Byte kBytes, MBytes and GBytes.
  # $1 is the raw size $2 is the units.

  FILE_SIZE_BYTES=0
  if [ -z "$1" ]
  then
    echo "No value passed in. Error converting to Bytes."
    return 12
  fi
  case "$2" in

    "B" | "b" )
    # Unit in Bytes
    let "FILE_SIZE_BYTES=$1"
    ;;

    "kB" | "kb" )
    # Unit in KiloBytes
    let "FILE_SIZE_BYTES=$1*1024"
    ;;

    "MB" | "mb" )
    # Unit in MegaBytes
    let "FILE_SIZE_BYTES=$1*1024*1024"
    ;;

    "GB" | "gb" )
    # Unit in GigaBytes
    let "FILE_SIZE_BYTES=$1*1024*1024*1024"
    ;;
  esac
  echo "Size in Bytes: $FILE_SIZE_BYTES"
}

function imgSzGet() {
  echo "Container Image Size:"
  $PD_PROVIDER images --no-trunc --format "{{.ID}} {{.Size}}" | grep "$HASH"

}

function getImageSizeLog() {
  getOldLog 004_imageSizeGet.sh
}

function getImageSizeRawFromLog() {
  RAW_IMAGE_SIZE=$(cat $(getImageSizeLog)| tail -1 | sed -n -e "s/^.*:$HASH //p" |  frontTrim | cut -d ' ' -f 1)
}

function getImageSizeUnitFromLog() {
  RAW_IMAGE_SIZE_UNIT=$(cat $(getImageSizeLog)| tail -1 | sed -n -e "s/^.*:$HASH //p" | frontTrim | cut -d ' ' -f 2)
}

function imgSzChck() {
  echo "Write Image Size to properties file."
  getImageSizeRawFromLog
  getImageSizeUnitFromLog
  convertToBytes $RAW_IMAGE_SIZE $RAW_IMAGE_SIZE_UNIT
  echo "Report file size in Bytes to ContainerQa Property File."

  echo "container.size.provider=${FILE_SIZE_BYTES}" >> $CONTAINERQA_PROPERTIES
}

function checkJavaHomeEnvVar() {
  echo "JAVA_HOME variable is: "
  runOnBaseDir bash -c 'echo $JAVA_HOME'
}

function checkJavaHomeEnvVarValid() {
  runOnBaseDir bash -c '$JAVA_HOME/bin/java -version'
}

function otherUserRun() {
  set +e
  #There is no test here. The call's output must be checked.
  runOnBaseDirOtherUser
  set -e
}

function getotherUserRunOldLog() {
  getOldLog 101-01__reproducerOPENJDK-533_otherUserRun.sh
}

function checkOtherUserWorks() {
  echo "Validate that other users beside the default user (default or jboss) can run the container."
  local OUTPUT=$(cat $(getotherUserRunOldLog)|grep "Permission denied") 

  test -z "$OUTPUT"
}

# This test is added to check that tar is installed in all Openjdk images.
#  https://issues.redhat.com/browse/OPENJDK-2588
function testTarIsInstalled() {
  runOnBaseDir  tar --version
}
#  SECTION FOR BUILDING CONTAINER IMAGES FOR TEST. 
#   Ultimately these may be broken out to seperate file.

function newUserCheck() {
  skipIfRhel7Execution
  local podmanfile=Containerfile
  local IMAGE_UNDER_TEST=$HASH

    cat <<EOF > $podmanfile
  FROM $IMAGE_UNDER_TEST
  USER root
  RUN whoami
  RUN adduser test
  RUN id test
EOF
    $PD_PROVIDER build -f $podmanfile .

}

function setAlgorithmTestsVars {
  # Turning the tests off for now as there are random failure that are slowing testing for respins.
  echo $SKIPPED3
  exit
  checkAlgorithmsCode=`cat $LIBCQA_SCRIPT_DIR/CheckAlgorithms.java | sed -e "s/'//g"` # the ' characters are escaping and making problems, deleting them here
  cipherListCode=`cat $LIBCQA_SCRIPT_DIR/CipherList.java`
}

function listCryptoAlgorithms() {
  skipIfJreExecution
  runOnBaseDirBash "echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                    javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list algorithms"
}

function listCryptoAlgorithmsWithFipsSet() {
  skipIfJreExecution
  skipIfRhel8FipsExecution
  runOnBaseDirBashRootUser "update-crypto-policies --set FIPS && \
                            echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                            javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list algorithms"
}

function listCryptoAlgorithmsWithoutFips() {
  skipIfJreExecution
  skipIfFipsExecution
  runOnBaseDirBashRootUser "fips-mode-setup --disable && \
                            echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                            javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list algorithms"
}

function listCryptoProviders() {
  skipIfJreExecution
  runOnBaseDirBash "echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                    javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list providers"
}

function listCryptoProvidersWithFipsSet() {
  skipIfJreExecution
  skipIfRhel8FipsExecution
  runOnBaseDirBashRootUser "update-crypto-policies --set FIPS && \
                            echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                            javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list providers"
}

function listCryptoProvidersWithoutFips() {
  skipIfJreExecution
  skipIfFipsExecution
  runOnBaseDirBashRootUser "fips-mode-setup --disable && \
                            echo '$checkAlgorithmsCode' > /tmp/CheckAlgorithms.java && echo '$cipherListCode' > /tmp/CipherList.java && \
                            javac -d /tmp /tmp/CheckAlgorithms.java /tmp/CipherList.java && java -cp /tmp CheckAlgorithms list providers"
}