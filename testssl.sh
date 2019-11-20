#!/usr/bin/env bash
#
# vim:ts=5:sw=5:expandtab
# we have a spaces softtab, that ensures readability with other editors too

# testssl.sh is a program for spotting weak SSL encryption, ciphers, version and some
# vulnerabilities or features
#
# Devel version is available from    https://github.com/drwetter/testssl.sh
# Stable version from                https://testssl.sh
# Please file bugs at github!        https://github.com/drwetter/testssl.sh/issues
#
# Project lead and initiator: Dirk Wetter, copyleft: 2007-today, contributions so far see CREDITS.md
# Main contributions from David Cooper
#
# License: GPLv2, see http://www.fsf.org/licensing/licenses/info/GPLv2.html
# and accompanying license "LICENSE.txt". Redistribution + modification under this
# license permitted.
# If you enclose this script or parts of it in your software, it has to
# be accompanied by the same license (see link) and the place where to get
# the recent version of this program. Do not violate the license and if
# you do not agree to all of these terms, do not use it in the first place.
#
# OpenSSL, which is being used and maybe distributed via one of this projects'
# web sites, is subject to their licensing: https://www.openssl.org/source/license.txt
#
# The client simulation data comes from SSLlabs and is licensed to the 'Qualys SSL Labs
# Terms of Use' (v2.2), see https://www.ssllabs.com/downloads/Qualys_SSL_Labs_Terms_of_Use.pdf,
# stating a CC BY 3.0 US license: https://creativecommons.org/licenses/by/3.0/us/
#
# Please note:  USAGE WITHOUT ANY WARRANTY, THE SOFTWARE IS PROVIDED "AS IS".
# USE IT AT your OWN RISK!
# Seriously! The threat is you run this code on your computer and input could be /
# is being supplied via untrusted sources.
#
# HISTORY:
# Back in 2006 it all started with a few openssl commands...
# That's because openssl is a such a good swiss army knife (see e.g.
# wiki.openssl.org/index.php/Command_Line_Utilities) that it was difficult to resist
# wrapping some shell commands around it, which I used for my pen tests. This is how
# everything started.
# Now it has grown up, it has bash socket support for most features, which has been basically
# replacing more and more functions of OpenSSL and some sockets functions serve as some kind
# of central functions.
#
# WHY BASH?
# Cross-platform is one of the three main goals of this script. Second: Ease of installation.
# No compiling, install gems, go to CPAN, use pip etc. Third: Easy to use and to interpret
# the results.
# /bin/bash including the builtin sockets fulfill all that.  The socket checks in bash may sound
# cool and unique -- they are -- but probably you can achieve e.g. the same result with my favorite
# interactive shell: zsh (zmodload zsh/net/socket -- checkout zsh/net/tcp) too! Oh, and btw.
# ksh93 has socket support too.
# /bin/bash though is way more often used within Linux and it's perfect for cross platform support.
# MacOS X has it and also under Windows the MSYS2 extension or Cygwin as well as Bash on Windows (WSL)
# has /bin/bash.
#
# Q: So what's the difference to www.ssllabs.com/ssltest/ or sslcheck.globalsign.com/ ?
# A: As of now ssllabs only check 1) webservers 2) on standard ports, 3) reachable from the
#    internet. And those examples above 4) are 3rd parties. If these restrictions are all fine
#    with you and you need a management compatible rating -- go ahead and use those.
#
# But also if your fine with those restrictions: testssl.sh is meant as a tool in your hand
# and it's way more flexible.  Oh, and did I mention testssl.sh is open source?
#
#################### Stop talking, action now ####################


########### Definition of error codes
#
declare -r ERR_BASH=255            # Bash version incorrect
declare -r ERR_CMDLINE=254         # Cmd line couldn't be parsed
declare -r ERR_FCREATE=253         # Output file couldn't be created
declare -r ERR_FNAMEPARSE=252      # Input file couldn't be parsed
declare -r ERR_NOSUPPORT=251       # Feature requested is not supported
declare -r ERR_OSSLBIN=250         # Problem with OpenSSL binary
declare -r ERR_DNSBIN=249          # Problem with DNS lookup binaries
declare -r ERR_OTHERCLIENT=248     # Other client problem
declare -r ERR_DNSLOOKUP=247       # Problem with resolving IP addresses or names
declare -r ERR_CONNECT=246         # Connectivity problem
declare -r ERR_CLUELESS=245        # Weird state, either though user options or testssl.sh
declare -r ERR_RESOURCE=244        # Resources testssl.sh needs couldn't be read
declare -r ERR_CHILD=242           # Child received a signal from master
declare -r ALLOK=0                 # All is fine


[ -z "${BASH_VERSINFO[0]}" ] && printf "\n\033[1;35m Please make sure you're using \"bash\"! Bye...\033[m\n\n" >&2 && exit $ERR_BASH
[ $(kill -l | grep -c SIG) -eq 0 ] && printf "\n\033[1;35m Please make sure you're calling me without leading \"sh\"! Bye...\033[m\n\n"  >&2 && exit $ERR_BASH
[ ${BASH_VERSINFO[0]} -lt 3 ] && printf "\n\033[1;35m Minimum requirement is bash 3.2. You have $BASH_VERSION \033[m\n\n"  >&2 && exit $ERR_BASH
[ ${BASH_VERSINFO[0]} -le 3 ] && [ ${BASH_VERSINFO[1]} -le 1 ] && printf "\n\033[1;35m Minimum requirement is bash 3.2. You have $BASH_VERSION \033[m\n\n"  >&2 && exit $ERR_BASH

########### Debugging helpers + profiling
#
declare -r PS4='|${LINENO}> \011${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
DEBUGTIME=${DEBUGTIME:-false}                     # stackoverflow.com/questions/5014823/how-to-profile-a-bash-shell-script-slow-startup#20855353, profiling bash
DEBUG_ALLINONE=${DEBUG_ALLINONE:-false}           # true: do debugging in one screen (old behavior for testssl.sh and bash3's default
                                                  # false: needed for performance analysis or useful for just having an extra file
DEBUG_ALLINONE=${SETX:-false}                     # SETX as a shortcut for old style debugging, overriding DEBUG_ALLINONE
if [[ "$SHELLOPTS" =~ xtrace ]]; then
     if "$DEBUGTIME"; then
          # separate debugging, doesn't mess up the screen, $DEBUGTIME determines whether we also do performance analysis
          exec 42>&2 2> >(tee /tmp/testssl-$$.log | sed -u 's/^.*$/now/' | date -f - +%s.%N >/tmp/testssl-$$.time)
          # BASH_XTRACEFD=42
     else
          if ! "$DEBUG_ALLINONE"; then
               exec 42>| /tmp/testssl-$$.log
               BASH_XTRACEFD=42
          fi
     fi
fi

########### Traps! Make sure that temporary files are cleaned up after use in ANY case
#
trap "cleanup" QUIT EXIT
trap "child_error" USR1


########### Internal definitions
#
declare -r VERSION="3.0rc5"
declare -r SWCONTACT="dirk aet testssl dot sh"
grep -E -q "dev|rc|beta" <<< "$VERSION" && \
     SWURL="https://testssl.sh/dev/" ||
     SWURL="https://testssl.sh/"
declare -r CVS_REL="$(tail -5 "$0" | awk '/dirkw Exp/ { print $4" "$5" "$6}')"
declare -r CVS_REL_SHORT="$(tail -5 "$0" | awk '/dirkw Exp/ { print $4 }')"
if git log &>/dev/null; then
     declare -r GIT_REL="$(git log --format='%h %ci' -1 2>/dev/null | awk '{ print $1" "$2" "$3 }')"
     declare -r GIT_REL_SHORT="$(git log --format='%h %ci' -1 2>/dev/null | awk '{ print $1 }')"
     declare -r REL_DATE="$(git log --format='%h %ci' -1 2>/dev/null | awk '{ print $2 }')"
else
     declare -r REL_DATE="$(tail -5 "$0" | awk '/dirkw Exp/ { print $5 }')"
fi
declare -r PROG_NAME="$(basename "$0")"
declare -r RUN_DIR="$(dirname "$0")"
declare -r SYSTEM="$(uname -s)"
declare -r SYSTEMREV="$(uname -r)"
SYSTEM2=""                                        # currently only being used for WSL = bash on windows
TESTSSL_INSTALL_DIR="${TESTSSL_INSTALL_DIR:-""}"  # If you run testssl.sh and it doesn't find it necessary file automagically set TESTSSL_INSTALL_DIR
CA_BUNDLES_PATH="${CA_BUNDLES_PATH:-""}"          # You can have your stores some place else
ADDITIONAL_CA_FILES="${ADDITIONAL_CA_FILES:-""}"  # single file with a CA in PEM format or comma separated lists of them
CIPHERS_BY_STRENGTH_FILE=""
TLS_DATA_FILE=""                                  # mandatory file for socket-based handshakes
OPENSSL_LOCATION=""
HNAME="$(hostname)"
HNAME="${HNAME%%.*}"

declare CMDLINE
declare -r -a CMDLINE_ARRAY=("$@")                # When performing mass testing, the child processes need to be sent the
declare -a MASS_TESTING_CMDLINE                   # command line in the form of an array (see #702 and http://mywiki.wooledge.org/BashFAQ/050).


########### Some predefinitions: date, sed (we always use test and not try to determine
#   capabilities by querying the OS)
#
HAS_GNUDATE=false
HAS_FREEBSDDATE=false
HAS_OPENBSDDATE=false
if date -d @735275209 >/dev/null 2>&1; then
     if date -r @735275209  >/dev/null 2>&1; then
          # it can't do any conversion from a plain date output
          HAS_OPENBSDDATE=true
     else
          HAS_GNUDATE=true
     fi
fi
# FreeBSD and OS X date(1) accept "-f inputformat"
date -j -f '%s' 1234567 >/dev/null 2>&1 && \
     HAS_FREEBSDDATE=true

echo A | sed -E 's/A//' >/dev/null 2>&1 && \
     declare -r HAS_SED_E=true || \
     declare -r HAS_SED_E=false

########### Terminal defintions
tty -s && \
     declare -r INTERACTIVE=true || \
     declare -r INTERACTIVE=false

if [[ -z $TERM_WIDTH ]]; then                               # no batch file and no otherwise predefined TERM_WIDTH
     if ! tput cols &>/dev/null || ! "$INTERACTIVE";then    # Prevent tput errors if running non interactive
          export TERM_WIDTH=${COLUMNS:-80}
     else
          export TERM_WIDTH=${COLUMNS:-$(tput cols)}        # for custom line wrapping and dashes
     fi
fi
TERM_CURRPOS=0                                              # custom line wrapping needs alter the current horizontal cursor pos


########### Defining (and presetting) variables which can be changed
#
# Following variables make use of $ENV and can be used like "OPENSSL=<myprivate_path_to_openssl> ./testssl.sh <URI>"
declare -x OPENSSL OPENSSL_TIMEOUT
PHONE_OUT=${PHONE_OUT:-false}           # Whether testssl can retrieve CRLs and OCSP
FAST_SOCKET=${FAST_SOCKET:-false}       # EXPERIMENTAL feature to accelerate sockets -- DO NOT USE it for production
COLOR=${COLOR:-2}                       # 3: Extra color (ciphers, curves), 2: Full color, 1: B/W only 0: No ESC at all
COLORBLIND=${COLORBLIND:-false}         # if true, swap blue and green in the output
SHOW_EACH_C=${SHOW_EACH_C:-false}       # where individual ciphers are tested show just the positively ones tested
SHOW_SIGALGO=${SHOW_SIGALGO:-false}     # "secret" switch whether testssl.sh shows the signature algorithm for -E / -e
SNEAKY=${SNEAKY:-false}                 # is the referer and useragent we leave behind just usual?
QUIET=${QUIET:-false}                   # don't output the banner. By doing this you acknowledge usage term appearing in the banner
SSL_NATIVE=${SSL_NATIVE:-false}         # we do per default bash sockets where possible "true": switch back to "openssl native"
ASSUME_HTTP=${ASSUME_HTTP:-false}       # in seldom cases (WAF, old servers, grumpy SSL) service detection fails. "True" enforces HTTP checks
BUGS=${BUGS:-""}                        # -bugs option from openssl, needed for some BIG IP F5
WARNINGS=${WARNINGS:-""}                # can be either off or batch
DEBUG=${DEBUG:-0}                       # 1: normal output the files in /tmp/ are kept for further debugging purposes
                                        # 2: list more what's going on , also lists some errors of connections
                                        # 3: slight hexdumps + other info,
                                        # 4: display bytes sent via sockets
                                        # 5: display bytes received via sockets
                                        # 6: whole 9 yards
FAST=${FAST:-false}                     # preference: show only first cipher, run_allciphers with openssl instead of sockets
WIDE=${WIDE:-false}                     # whether to display for some options just ciphers or a table w hexcode/KX,Enc,strength etc.
MASS_TESTING_MODE=${MASS_TESTING_MODE:-serial}    # can be serial or parallel. Subject to change
LOGFILE="${LOGFILE:-""}"                # logfile if used
JSONFILE="${JSONFILE:-""}"              # jsonfile if used
CSVFILE="${CSVFILE:-""}"                # csvfile if used
HTMLFILE="${HTMLFILE:-""}"              # HTML if used
FNAME=${FNAME:-""}                      # file name to read commands from
FNAME_PREFIX=${FNAME_PREFIX:-""}        # output filename prefix, see --outprefix
APPEND=${APPEND:-false}                 # append to csv/json file instead of overwriting it
[[ -z "$NODNS" ]] && declare NODNS      # If unset it does all DNS lookups per default. "min" only for hosts or "none" at all
HAS_IPv6=${HAS_IPv6:-false}             # if you have OpenSSL with IPv6 support AND IPv6 networking set it to yes
ALL_CLIENTS=${ALL_CLIENTS:-false}       # do you want to run all client simulation form all clients supplied by SSLlabs?
OFFENSIVE=${OFFENSIVE:-true}            # do you want to include offensive vulnerability tests which may cause blocking by an IDS?

########### Tuning vars which cannot be set by a cmd line switch. Use instead e.g "HEADER_MAXSLEEP=10 ./testssl.sh <your_args_here>"
#
EXPERIMENTAL=${EXPERIMENTAL:-false}     # a development hook which allows us to disable code
PROXY_WAIT=${PROXY_WAIT:-20}            # waiting at max 20 seconds for socket reply through proxy
DNS_VIA_PROXY=${DNS_VIA_PROXY:-true}    # do DNS lookups via proxy. --ip=proxy reverses this
IGN_OCSP_PROXY=${IGN_OCSP_PROXY:-false} # Also when --proxy is supplied it is ignored when testing for revocation via OCSP via --phone-out
HEADER_MAXSLEEP=${HEADER_MAXSLEEP:-5}   # we wait this long before killing the process to retrieve a service banner / http header
MAX_SOCKET_FAIL=${MAX_SOCKET_FAIL:-2}   # If this many failures for TCP socket connects are reached we terminate
MAX_OSSL_FAIL=${MAX_OSSL_FAIL:-2}       # If this many failures for s_client connects are reached we terminate
MAX_HEADER_FAIL=${MAX_HEADER_FAIL:-2}   # If this many failures for HTTP GET are encountered we don't try again to get the header
MAX_WAITSOCK=${MAX_WAITSOCK:-10}        # waiting at max 10 seconds for socket reply. There shouldn't be any reason to change this.
CCS_MAX_WAITSOCK=${CCS_MAX_WAITSOCK:-5} # for the two CCS payload (each). There shouldn't be any reason to change this.
HEARTBLEED_MAX_WAITSOCK=${HEARTBLEED_MAX_WAITSOCK:-8}      # for the heartbleed payload. There shouldn't be any reason to change this.
STARTTLS_SLEEP=${STARTTLS_SLEEP:-10}    # max time wait on a socket for STARTTLS. MySQL has a fixed value of 1 which can't be overwritten (#914)
FAST_STARTTLS=${FAST_STARTTLS:-true}    # at the cost of reliability decrease the handshakes for STARTTLS
USLEEP_SND=${USLEEP_SND:-0.1}           # sleep time for general socket send
USLEEP_REC=${USLEEP_REC:-0.2}           # sleep time for general socket receive
HSTS_MIN=${HSTS_MIN:-179}               # >179 days is ok for HSTS
     HSTS_MIN=$((HSTS_MIN * 86400))     # correct to seconds
HPKP_MIN=${HPKP_MIN:-30}                # >=30 days should be ok for HPKP_MIN, practical hints?
     HPKP_MIN=$((HPKP_MIN * 86400))     # correct to seconds
DAYS2WARN1=${DAYS2WARN1:-60}            # days to warn before cert expires, threshold 1
DAYS2WARN2=${DAYS2WARN2:-30}            # days to warn before cert expires, threshold 2
VULN_THRESHLD=${VULN_THRESHLD:-1}       # if vulnerabilities to check >$VULN_THRESHLD we DON'T show a separate header line in the output each vuln. check
UNBRACKTD_IPV6=${UNBRACKTD_IPV6:-false} # some versions of OpenSSL (like Gentoo) don't support [bracketed] IPv6 addresses
NO_ENGINE=${NO_ENGINE:-false}           # if there are problems finding the (external) openssl engine set this to true
declare -r CLIENT_MIN_PFS=5             # number of ciphers needed to run a test for PFS
CAPATH="${CAPATH:-/etc/ssl/certs/}"     # Does nothing yet (FC has only a CA bundle per default, ==> openssl version -d)
GOOD_CA_BUNDLE=""                       # A bundle of CA certificates that can be used to validate the server's certificate
CERTIFICATE_LIST_ORDERING_PROBLEM=false # Set to true if server sends a certificate list that contains a certificate
                                        # that does not certify the one immediately preceding it. (See RFC 8446, Section 4.4.2)
STAPLED_OCSP_RESPONSE=""
HAS_DNS_SANS=false                      # Whether the certificate includes a subjectAltName extension with a DNS name or an application-specific identifier type.
MEASURE_TIME_FILE=${MEASURE_TIME_FILE:-""}
if [[ -n "$MEASURE_TIME_FILE" ]] && [[ -z "$MEASURE_TIME" ]]; then
     MEASURE_TIME=true
else
     MEASURE_TIME=${MEASURE_TIME:-false}
fi
DISPLAY_CIPHERNAMES="openssl"           # display OpenSSL ciphername (but both OpenSSL and RFC ciphernames in wide mode)
declare -r UA_STD="TLS tester from $SWURL"
declare -r UA_SNEAKY="Mozilla/5.0 (X11; Linux x86_64; rv:52.0) Gecko/20100101 Firefox/52.0"

########### Initialization part, further global vars just being declared here
#
PRINTF=""                               # which external printf to use. Empty presets the internal one, see #1130
IKNOW_FNAME=false
FIRST_FINDING=true                      # is this the first finding we are outputting to file?
JSONHEADER=true                         # include JSON headers and footers in HTML file, if one is being created
CSVHEADER=true                          # same for CSV
HTMLHEADER=true                         # same for HTML
SECTION_FOOTER_NEEDED=false             # kludge for tracking whether we need to close the JSON section object
GIVE_HINTS=false                        # give an additional info to findings
SERVER_SIZE_LIMIT_BUG=false             # Some servers have either a ClientHello total size limit or a 128 cipher limit (e.g. old ASAs)
MULTIPLE_CHECKS=false                   # need to know whether an MX record or a hostname resolves to multiple IPs to check
CHILD_MASS_TESTING=${CHILD_MASS_TESTING:-false}
HAD_SLEPT=0
NR_SOCKET_FAIL=0                        # Counter for socket failures
NR_OSSL_FAIL=0                          # .. for OpenSSL connects
NR_HEADER_FAIL=0                        # .. for HTTP_GET
PROTOS_OFFERED=""                       # This keeps which protocol is being offered. See has_server_protocol().
TLS12_CIPHER_OFFERED=""                 # This contains the hexcode of a cipher known to be supported by the server with TLS 1.2
CURVES_OFFERED=""                       # This keeps which curves have been detected. Just for error handling
KNOWN_OSSL_PROB=false                   # We need OpenSSL a few times. This variable is an indicator if we can't connect. Eases handling
DETECTED_TLS_VERSION=""                 # .. as hex string, e.g. 0300 or 0303
TLS13_ONLY=false                        # Does the server support TLS 1.3 ONLY?
OSSL_SHORTCUT=${OSSL_SHORTCUT:-false}   # Hack: if during the scan turns out the OpenSSL binary suports TLS 1.3 would be a better choice, this enables it.
TLS_EXTENSIONS=""
declare -r NPN_PROTOs="spdy/4a2,spdy/3,spdy/3.1,spdy/2,spdy/1,http/1.1"
# alpn_protos needs to be space-separated, not comma-seperated, including odd ones observed @ facebook and others, old ones like h2-17 omitted as they could not be found
declare -r ALPN_PROTOs="h2 spdy/3.1 http/1.1 grpc-exp h2-fb spdy/1 spdy/2 spdy/3 stun.turn stun.nat-discovery webrtc c-webrtc ftp"
declare -a SESS_RESUMPTION
TEMPDIR=""
TMPFILE=""
ERRFILE=""
CLIENT_AUTH=false
TLS_TICKETS=false
NO_SSL_SESSIONID=false
CERT_COMPRESSION=${CERT_COMPRESSION:-false}  # secret flag to set in addition to --devel for certificate compression
HOSTCERT=""                                  # File with host certificate, without intermediate certificate
HEADERFILE=""
HEADERVALUE=""
HTTP_STATUS_CODE=""
DH_GROUP_OFFERED=""
DH_GROUP_LEN_P=0
KEY_SHARE_EXTN_NR="33"                  # The extension number for key_share was changed from 40 to 51 in TLSv1.3 draft 23.
                                        # In order to support draft 23 and later in addition to earlier drafts, need to
                                        # know which extension number to use. Note that it appears that a single
                                        # ClientHello cannot advertise both draft 23 and later and earlier drafts.
                                        # Preset may help to deal with STARTTLS + TLS 1.3 draft 23 and later but not earlier.
BAD_SERVER_HELLO_CIPHER=false           # reserved for cases where a ServerHello doesn't contain a cipher offered in the ClientHello
GOST_STATUS_PROBLEM=false
PATTERN2SHOW=""
SOCK_REPLY_FILE=""
NW_STR=""
LEN_STR=""
SNI=""
POODLE=""                               # keep vulnerability status for TLS_FALLBACK_SCSV
OSSL_NAME=""                            # openssl name, in case of LibreSSL it's LibreSSL
OSSL_VER=""                             # openssl version, will be auto-determined
OSSL_VER_MAJOR=0
OSSL_VER_MINOR=0
OSSL_VER_APPENDIX="none"
CLIENT_PROB_NO=1
HAS_DH_BITS=${HAS_DH_BITS:-false}       # initialize openssl variables
OSSL_SUPPORTED_CURVES=""
HAS_SSL2=false
HAS_SSL3=false
HAS_TLS13=false
HAS_X448=false
HAS_X25519=false
HAS_PKUTIL=false
HAS_PKEY=false
HAS_NO_SSL2=false
HAS_NOSERVERNAME=false
HAS_CIPHERSUITES=false
HAS_COMP=false
HAS_NO_COMP=false
HAS_ALPN=false
HAS_NPN=false
HAS_FALLBACK_SCSV=false
HAS_PROXY=false
HAS_XMPP=false
HAS_POSTGRES=false
HAS_MYSQL=false
HAS_LMTP=false
HAS_NNTP=false
HAS_IRC=false
HAS_CHACHA20=false
HAS_AES128_GCM=false
HAS_AES256_GCM=false
HAS_ZLIB=false
HAS_DIG=false
HAS_HOST=false
HAS_DRILL=false
HAS_NSLOOKUP=false
HAS_IDN=false
HAS_IDN2=false
HAS_AVAHIRESOLVE=false
HAS_DIG_NOIDNOUT=false

OSSL_CIPHERS_S=""
PORT=443                                # unless otherwise auto-determined, see below
NODE=""
NODEIP=""
rDNS=""
CORRECT_SPACES=""                       # Used for IPv6 and proper output formatting
IPADDRs=""
IP46ADDRs=""
LOCAL_A=false                           # Does the $NODEIP come from /etc/hosts?
LOCAL_AAAA=false                        # Does the IPv6 IP come from /etc/hosts?
XMPP_HOST=""
PROXYIP=""                              # $PROXYIP:$PROXPORT is your proxy if --proxy is defined ...
PROXYPORT=""                            # ... and openssl has proxy support
PROXY=""                                # Once check_proxy() executed it contains $PROXYIP:$PROXPORT
VULN_COUNT=0
SERVICE=""                              # Is the server running an HTTP server, SMTP, POP or IMAP?
URI=""
CERT_FINGERPRINT_SHA2=""
RSA_CERT_FINGERPRINT_SHA2=""
STARTTLS_PROTOCOL=""
OPTIMAL_PROTO=""                        # Need this for IIS6 (sigh) + OpenSSL 1.0.2, otherwise some handshakes will fail see
                                        # https://github.com/PeterMosmans/openssl/issues/19#issuecomment-100897892
STARTTLS_OPTIMAL_PROTO=""               # Same for STARTTLS, see https://github.com/drwetter/testssl.sh/issues/188
OPTIMAL_SOCKETS_PROTO=""                # Same for tls_sockets(). -- not yet used
ALL_FAILED_SOCKETS=true                 # Set to true if all attempts to connect to server using tls_sockets/sslv2_sockets failed
TLS_TIME=""                             # To keep the value of TLS server timestamp
TLS_NOW=""                              # Similar
TLS_DIFFTIME_SET=false                  # Tells TLS functions to measure the TLS difftime or not
NOW_TIME=""
HTTP_TIME=""
GET_REQ11=""
START_TIME=0                            # time in epoch when the action started
END_TIME=0                              # .. ended
SCAN_TIME=0                             # diff of both: total scan time
LAST_TIME=0                             # only used for performance measurements (MEASURE_TIME=true)
SERVER_COUNTER=0                        # Counter for multiple servers

TLS_LOW_BYTE=""                         # For "secret" development stuff, see -q below
HEX_CIPHER=""                           # "


########### Global variables for parallel mass testing
#
declare -r PARALLEL_SLEEP=1               # Time to sleep after starting each test
MAX_WAIT_TEST=${MAX_WAIT_TEST:-1200}      # Maximum time (in seconds) to wait for a test to complete
MAX_PARALLEL=${MAX_PARALLEL:-20}          # Maximum number of tests to run in parallel
                                          # This value may be made larger on systems with faster processors
declare -a -i PARALLEL_TESTING_PID=()     # process id for each child test (or 0 to indicate test has already completed)
declare -a PARALLEL_TESTING_CMDLINE=()    # command line for each child test
declare -i NR_PARALLEL_TESTS=0            # number of parallel tests run
declare -i NEXT_PARALLEL_TEST_TO_FINISH=0 # number of parallel tests that have completed and have been processed
declare FIRST_JSON_OUTPUT=true            # true if no output has been added to $JSONFILE yet.


########### Cipher suite information
#
declare -i TLS_NR_CIPHERS=0
declare TLS_CIPHER_HEXCODE=()
declare TLS_CIPHER_OSSL_NAME=()
declare TLS_CIPHER_RFC_NAME=()
declare TLS_CIPHER_SSLVERS=()
declare TLS_CIPHER_KX=()
declare TLS_CIPHER_AUTH=()
declare TLS_CIPHER_ENC=()
declare TLS_CIPHER_EXPORT=()
declare TLS_CIPHER_OSSL_SUPPORTED=()
declare TLS13_OSSL_CIPHERS="TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_CCM_SHA256:TLS_AES_128_CCM_8_SHA256"

########### Severity functions and globals
#
INFO=0
OK=0
LOW=1
MEDIUM=2
HIGH=3
CRITICAL=4
SEVERITY_LEVEL=0

set_severity_level() {
   local severity=$1

   if [[ "$severity" == LOW ]]; then
           SEVERITY_LEVEL=$LOW
   elif [[ "$severity" == MEDIUM ]]; then
           SEVERITY_LEVEL=$MEDIUM
   elif [[ "$severity" == HIGH ]]; then
           SEVERITY_LEVEL=$HIGH
   elif [[ "$severity" == CRITICAL ]]; then
           SEVERITY_LEVEL=$CRITICAL
   else
        # WARN and FATAL will always be logged as the represent scanning problems
        echo "Supported severity levels are LOW, MEDIUM, HIGH, CRITICAL!"
        help 1
   fi
}

show_finding() {
   local severity=$1

   ( [[ "$severity" == DEBUG ]] ) ||
   ( [[ "$severity" == INFO ]] && [[ $SEVERITY_LEVEL -le $INFO ]] ) ||
   ( [[ "$severity" == OK ]] && [[ $SEVERITY_LEVEL -le $OK ]] ) ||
   ( [[ "$severity" == LOW ]] && [[ $SEVERITY_LEVEL -le $LOW ]] ) ||
   ( [[ "$severity" == MEDIUM ]] && [[ $SEVERITY_LEVEL -le $MEDIUM ]] ) ||
   ( [[ "$severity" == HIGH ]] && [[ $SEVERITY_LEVEL -le $HIGH ]] ) ||
   ( [[ "$severity" == CRITICAL ]] && [[ $SEVERITY_LEVEL -le $CRITICAL ]] ) ||
   ( [[ "$severity" == WARN ]] ) ||
   ( [[ "$severity" == FATAL ]] )
}

########### Output functions

# For HTML output, replace any HTML reserved characters with the entity name
html_reserved(){
     local output
     "$do_html" || return 0
     #sed  -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<< "$1"
     output="${1//\&/\&amp;}"
     output="${output//</\&lt;}"
     output="${output//>/\&gt;}"
     output="${output//\"/\&quot;}"
     output="${output//\'/\&apos;}"
     tm_out "$output"
     return 0
}

html_out() {
     "$do_html" || return 0
     [[ -n "$HTMLFILE" ]] && [[ ! -d "$HTMLFILE" ]] && printf -- "%b" "${1//%/%%}" >> "$HTMLFILE"
     # here and other printf's: a little bit of sanitizing with bash internal search&replace -- otherwise printf will hiccup at '%'. '--' and %b do the rest.
}

# This is intentionally the same.
safe_echo()  { printf -- "%b" "${1//%/%%}"; }
tm_out()     { printf -- "%b" "${1//%/%%}"; }
tmln_out()   { printf -- "%b" "${1//%/%%}\n"; }

out()   { printf -- "%b" "${1//%/%%}"; html_out "$1"; }
outln() { printf -- "%b" "${1//%/%%}\n"; html_out "$1\n"; }

#TODO: Still no shell injection safe but if just run it from the cmd line: that's fine

# Color print functions, see also http://www.tldp.org/HOWTO/Bash-Prompt-HOWTO/x329.html
tm_liteblue()   { [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && tm_out "\033[0;32m$1" || tm_out "\033[0;34m$1" ) || tm_out "$1"; tm_off; }    # not yet used
pr_liteblue()   { tm_liteblue "$1"; [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && html_out "<span style=\"color:#00cd00;\">$(html_reserved "$1")</span>" || html_out "<span style=\"color:#0000ee;\">$(html_reserved "$1")</span>" ) || html_out "$(html_reserved "$1")"; }
tmln_liteblue() { tm_liteblue "$1"; tmln_out; }
prln_liteblue() { pr_liteblue "$1"; outln; }

tm_blue()       { [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && tm_out "\033[1;32m$1" || tm_out "\033[1;34m$1" ) || tm_out "$1"; tm_off; }    # used for head lines of single tests
pr_blue()       { tm_blue "$1"; [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && html_out "<span style=\"color:lime;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "<span style=\"color:#5c5cff;font-weight:bold;\">$(html_reserved "$1")</span>" ) || html_out "$(html_reserved "$1")"; }
tmln_blue()     { tm_blue "$1"; tmln_out; }
prln_blue()     { pr_blue "$1"; outln; }

# we should be able to use aliases here
tm_warning()    { [[ "$COLOR" -ge 2 ]] && tm_out "\033[0;35m$1" || tm_underline "$1"; tm_off; }                   # some local problem: one test cannot be done
tmln_warning()  { tm_warning "$1"; tmln_out; }                                                                    # litemagenta
pr_warning()    { tm_warning "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:#cd00cd;\">$(html_reserved "$1")</span>" || ( [[ "$COLOR" -eq 1 ]] && html_out "<u>$(html_reserved "$1")</u>" || html_out "$(html_reserved "$1")" ); }
prln_warning()  { pr_warning "$1"; outln; }

tm_magenta()    { [[ "$COLOR" -ge 2 ]] && tm_out "\033[1;35m$1" || tm_underline "$1"; tm_off; }                   # fatal error: quitting because of this!
tmln_magenta()  { tm_magenta "$1"; tmln_out; }
# different as warning above?
pr_magenta()    { tm_magenta "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:magenta;font-weight:bold;\">$(html_reserved "$1")</span>" || ( [[ "$COLOR" -eq 1 ]] && html_out "<u>$(html_reserved "$1")</u>" || html_out "$(html_reserved "$1")" ); }
prln_magenta()  { pr_magenta "$1"; outln; }

tm_litecyan()   { [[ "$COLOR" -ge 2 ]] && tm_out "\033[0;36m$1" || tm_out "$1"; tm_off; }                         # not yet used
tmln_litecyan() { tm_litecyan "$1"; tmln_out; }
pr_litecyan()   { tm_litecyan "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:#00cdcd;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
prln_litecyan() { pr_litecyan "$1"; outln; }

tm_cyan()       { [[ "$COLOR" -ge 2 ]] && tm_out "\033[1;36m$1" || tm_out "$1"; tm_off; }                         # additional hint
tmln_cyan()     { tm_cyan "$1"; tmln_out; }
pr_cyan()       { tm_cyan "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:cyan;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
prln_cyan()     { pr_cyan "$1"; outln; }

tm_litegrey()   { [[ "$COLOR" -ne 0 ]] && tm_out "\033[0;37m$1" || tm_out "$1"; tm_off; }                         # ... https://github.com/drwetter/testssl.sh/pull/600#issuecomment-276129876
tmln_litegrey() { tm_litegrey "$1"; tmln_out; }                                                                   # not really usable on a black background, see ..
prln_litegrey() { pr_litegrey "$1"; outln; }
pr_litegrey()   { tm_litegrey "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"color:darkgray;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }

tm_grey()       { [[ "$COLOR" -ne 0 ]] && tm_out "\033[1;30m$1" || tm_out "$1"; tm_off; }
pr_grey()       { tm_grey "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"color:#7f7f7f;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
tmln_grey()     { tm_grey "$1"; tmln_out; }
prln_grey()     { pr_grey "$1"; outln; }

tm_svrty_good()   { [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && tm_out "\033[0;34m$1" || tm_out "\033[0;32m$1" ) || tm_out "$1"; tm_off; }   # litegreen (liteblue), This is good
tmln_svrty_good() { tm_svrty_good "$1"; tmln_out; }
pr_svrty_good()   { tm_svrty_good "$1"; [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && html_out "<span style=\"color:#0000ee;\">$(html_reserved "$1")</span>" || html_out "<span style=\"color:#00cd00;\">$(html_reserved "$1")</span>" ) || html_out "$(html_reserved "$1")"; }
prln_svrty_good() { pr_svrty_good "$1"; outln; }

tm_svrty_best()   { [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && tm_out "\033[1;34m$1" || tm_out "\033[1;32m$1" ) ||  tm_out "$1"; tm_off; }  # green (blue), This is the best
tmln_svrty_best() { tm_svrty_best "$1"; tmln_out; }
pr_svrty_best()   { tm_svrty_best "$1"; [[ "$COLOR" -ge 2 ]] && ( "$COLORBLIND" && html_out "<span style=\"color:#5c5cff;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "<span style=\"color:lime;font-weight:bold;\">$(html_reserved "$1")</span>" ) || html_out "$(html_reserved "$1")"; }
prln_svrty_best() { pr_svrty_best "$1"; outln; }

tm_svrty_low()     { [[ "$COLOR" -ge 2 ]] && tm_out "\033[1;33m$1" || tm_out "$1"; tm_off; }         # yellow brown | academic or minor problem
tmln_svrty_low()   { tm_svrty_low "$1"; tmln_out; }
pr_svrty_low()     { tm_svrty_low "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:#cdcd00;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
prln_svrty_low()   { pr_svrty_low "$1"; outln; }

tm_svrty_medium()  { [[ "$COLOR" -ge 2 ]] && tm_out "\033[0;33m$1" || tm_out "$1"; tm_off; }         # brown | it is not a bad problem but you shouldn't do this
pr_svrty_medium()  { tm_svrty_medium "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:#cd8000;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
tmln_svrty_medium(){ tm_svrty_medium "$1"; tmln_out; }
prln_svrty_medium(){ pr_svrty_medium "$1"; outln; }

tm_svrty_high()    { [[ "$COLOR" -ge 2 ]] && tm_out "\033[0;31m$1" || tm_bold "$1"; tm_off; }               # litered
pr_svrty_high()    { tm_svrty_high "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:#cd0000;\">$(html_reserved "$1")</span>" || ( [[ "$COLOR" -eq 1 ]] && html_out "<span style=\"font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")" ); }
tmln_svrty_high()  { tm_svrty_high "$1"; tmln_out; }
prln_svrty_high()  { pr_svrty_high "$1"; outln; }

tm_svrty_critical()   { [[ "$COLOR" -ge 2 ]] && tm_out "\033[1;31m$1" || tm_bold "$1"; tm_off; }           # red
pr_svrty_critical()   { tm_svrty_critical "$1"; [[ "$COLOR" -ge 2 ]] && html_out "<span style=\"color:red;font-weight:bold;\">$(html_reserved "$1")</span>" || ( [[ "$COLOR" -eq 1 ]] && html_out "<span style=\"font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")" ); }
tmln_svrty_critical() { tm_svrty_critical "$1"; tmln_out; }
prln_svrty_critical() { pr_svrty_critical "$1"; outln; }

tm_deemphasize()      { tm_out "$1"; }                                                                   # hook for a weakened screen output, see #600
pr_deemphasize()      { tm_deemphasize "$1"; html_out "<span style=\"color:darkgray;\">$(html_reserved "$1")</span>"; }
tmln_deemphasize()    { tm_deemphasize "$1"; tmln_out; }
prln_deemphasize()    { pr_deemphasize "$1"; outln; }

# color=1 functions
tm_off()        { [[ "$COLOR" -ne 0 ]] && tm_out "\033[m"; }

tm_bold()       { [[ "$COLOR" -ne 0 ]] && tm_out "\033[1m$1" || tm_out "$1"; tm_off; }
tmln_bold()     { tm_bold "$1"; tmln_out; }
pr_bold()       { tm_bold "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
prln_bold()     { pr_bold "$1" ; outln; }

NO_ITALICS=false
if [[ $SYSTEM == OpenBSD ]]; then
     NO_ITALICS=true
elif [[ $SYSTEM == FreeBSD ]]; then
     if [[ ${SYSTEMREV%\.*} -le 9 ]]; then
          NO_ITALICS=true
     fi
fi
tm_italic()     { ( [[ "$COLOR" -ne 0 ]] && ! "$NO_ITALICS" ) && tm_out "\033[3m$1" || tm_out "$1"; tm_off; }
tmln_italic()   { tm_italic "$1" ; tmln_out; }
pr_italic()     { tm_italic "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<i>$(html_reserved "$1")</i>" || html_out "$(html_reserved "$1")"; }
prln_italic()   { pr_italic "$1"; outln; }

tm_strikethru()   { [[ "$COLOR" -ne 0 ]] && tm_out "\033[9m$1" || tm_out "$1"; tm_off; }                          # ugly!
tmln_strikethru() { tm_strikethru "$1"; tmln_out; }
pr_strikethru()   { tm_strikethru "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<strike>$(html_reserved "$1")</strike>" || html_out "$(html_reserved "$1")"; }
prln_strikethru() { pr_strikethru "$1" ; outln; }

tm_underline()    { [[ "$COLOR" -ne 0 ]] && tm_out "\033[4m$1" || tm_out "$1"; tm_off; }
tmln_underline()  { tm_underline "$1"; tmln_out; }
pr_underline()    { tm_underline "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<u>$(html_reserved "$1")</u>" || html_out "$(html_reserved "$1")"; }
prln_underline()  { pr_underline "$1"; outln; }

tm_reverse()      { [[ "$COLOR" -ne 0 ]] && tm_out "\033[7m$1" || tm_out "$1"; tm_off; }
tm_reverse_bold() { [[ "$COLOR" -ne 0 ]] && tm_out "\033[7m\033[1m$1" || tm_out "$1"; tm_off; }
pr_reverse()      { tm_reverse "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"color:white;background-color:black;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
pr_reverse_bold() { tm_reverse_bold "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"color:white;background-color:black;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }

#pr_headline() { pr_blue "$1"; }
#http://misc.flogisoft.com/bash/tip_colors_and_formatting

#pr_headline() { [[ "$COLOR" -ge 2 ]] && out "\033[1;30m\033[47m$1" || out "$1"; tm_off; }
tm_headline()   { [[ "$COLOR" -ne 0 ]] && tm_out "\033[1m\033[4m$1" || tm_out "$1"; tm_off; }
tmln_headline() { tm_headline "$1"; tmln_out; }
pr_headline()   { tm_headline "$1"; [[ "$COLOR" -ne 0 ]] && html_out "<span style=\"text-decoration:underline;font-weight:bold;\">$(html_reserved "$1")</span>" || html_out "$(html_reserved "$1")"; }
pr_headlineln() { pr_headline "$1" ; outln; }

tm_squoted() { tm_out "'$1'"; }
pr_squoted() { out "'$1'"; }
tm_dquoted() { tm_out "\"$1\""; }
pr_dquoted() { out "\"$1\""; }

# either files couldn't be found or openssl isn't good enough (which shouldn't happen anymore)
tm_local_problem()   { tm_warning "Local problem: $1"; }
tmln_local_problem() { tmln_warning "Local problem: $1"; }
pr_local_problem()   { pr_warning "Local problem: $1"; }
prln_local_problem() { prln_warning "Local problem: $1"; }

# general failure
tm_fixme()   { tm_warning "Fixme: $1"; }
tmln_fixme() { tmln_warning "Fixme: $1"; }
pr_fixme()   { pr_warning "Fixme: $1"; }
prln_fixme() { prln_warning "Fixme: $1"; }

pr_url()     { tm_out "$1"; html_out "<a href=\"$1\" style=\"color:black;text-decoration:none;\">$1</a>"; }
pr_boldurl() { tm_bold "$1"; html_out "<a href=\"$1\" style=\"font-weight:bold;color:black;text-decoration:none;\">$1</a>"; }

### color switcher (see e.g. https://linuxtidbits.wordpress.com/2008/08/11/output-color-on-bash-scripts/
###                          http://www.tldp.org/HOWTO/Bash-Prompt-HOWTO/x405.html
### no output support for HTML!
set_color_functions() {
     local ncurses_tput=true

     if [[ $SYSTEM == OpenBSD ]] && [[ "$TERM" =~ xterm-256 ]]; then
          export TERM=xterm
          # OpenBSD can't handle 256 colors (yet) in xterm which might lead to ugly errors
          # like "tput: not enough arguments (3) for capability `AF'". Not our fault but
          # before we get blamed we fix it here.
     fi

     # Empty all vars if we have COLOR=0 equals no escape code -- these are globals:
     red=""
     green=""
     brown=""
     blue=""
     magenta=""
     cyan=""
     grey=""
     yellow=""
     off=""
     bold=""
     underline=""
     italic=""

     type -p tput &>/dev/null || return 0      # Hey wait, do we actually have tput / ncurses ?
     tput cols &>/dev/null || return 0         # tput under BSDs and GNUs doesn't work either (TERM undefined?)
     tput sgr0 &>/dev/null || ncurses_tput=false
     if [[ "$COLOR" -ge 2 ]]; then
          if $ncurses_tput; then
               red=$(tput setaf 1)
               green=$(tput setaf 2)
               brown=$(tput setaf 3)
               blue=$(tput setaf 4)
               magenta=$(tput setaf 5)
               cyan=$(tput setaf 6)
               grey=$(tput setaf 7)
               yellow=$(tput setaf 3; tput bold)
          else                                    # this is a try for old BSD, see terminfo(5)
               red=$(tput AF 1)
               green=$(tput AF 2)
               brown=$(tput AF 3)
               blue=$(tput AF 4)
               magenta=$(tput AF 5)
               cyan=$(tput AF 6)
               grey=$(tput AF 7)
               yellow=$(tput AF 3; tput md)
          fi
     fi
     if [[ "$COLOR" -ge 1 ]]; then
          if $ncurses_tput; then
               bold=$(tput bold)
               underline=$(tput sgr 0 1 2>/dev/null)
               italic=$(tput sitm)                # This doesn't work on FreeBSDi (9,10) and OpenBSD ...
               italic_end=$(tput ritm)            # ... and this, too
               off=$(tput sgr0)
          else                                    # this is a try for old BSD, see terminfo(5)
               bold=$(tput md)
               underline=$(tput us)
               italic=$(tput ZH 2>/dev/null)       # This doesn't work on FreeBSDi (9,10) and OpenBSD
               italic_end=$(tput ZR 2>/dev/null)   # ... probably entry missing in /etc/termcap
               reverse=$(tput mr)
               off=$(tput me)
          fi
     fi
     # FreeBSD 10 understands ESC codes like 'echo -e "\e[3mfoobar\e[23m"', but also no tput for italics
}

strip_quote() {
     # remove color codes (see http://www.commandlinefu.com/commands/view/3584/remove-color-codes-special-characters-with-sed)
     #  \', leading and all trailing spaces
     sed -e "s,$(echo -e "\033")\[[0-9;]*[a-zA-Z],,g" \
          -e "s/\"/\\'/g" \
          -e 's/^ *//g' \
          -e 's/ *$//g' <<< "$1"
}

# " deconfuse vim\'s syntax highlighting ;-)

#################### JSON FILE FORMATTING ####################

fileout_json_footer() {
     if "$do_json"; then
          if [[ "$SCAN_TIME" -eq 0 ]]; then
               fileout_json_finding "scanTime" "WARN" "Scan interrupted" "" "" ""
          elif [[ $SEVERITY_LEVEL -lt $LOW ]] ; then
               # no scan time in --severity=low and above, also needed for Travis, hackish...
               fileout_json_finding "scanTime" "INFO" $SCAN_TIME "" "" ""
          fi
          printf "]\n" >> "$JSONFILE"
     fi
     if "$do_pretty_json"; then
          if [[ "$SCAN_TIME" -eq 0 ]]; then
               echo -e "          ],\n                    \"scanTime\"  : \"Scan interrupted\"\n}" >> "$JSONFILE"
          else
               echo -e "          ],\n                    \"scanTime\"  : ${SCAN_TIME}\n}" >> "$JSONFILE"
          fi
     fi
}

fileout_json_section() {
     case $1 in
           0) echo -e    "                    \"pretest\"           : [" ;;
           1) echo -e    "                    \"singleCipher\"      : [" ;;
           2) echo -e ",\n                    \"protocols\"         : [" ;;
           3) echo -e ",\n                    \"grease\"            : [" ;;
           4) echo -e ",\n                    \"ciphers\"           : [" ;;
           5) echo -e ",\n                    \"pfs\"               : [" ;;
           6) echo -e ",\n                    \"serverPreferences\" : [" ;;
           7) echo -e ",\n                    \"serverDefaults\"    : [" ;;
           8) echo -e ",\n                    \"headerResponse\"    : [" ;;
           9) echo -e ",\n                    \"vulnerabilities\"   : [" ;;
          10) echo -e ",\n                    \"cipherTests\"       : [" ;;
          11) echo -e ",\n                    \"browserSimulations\": [" ;;
           *) echo "invalid section" ;;
     esac
}

fileout_section_header() {
    local str=""
    "$2" && str="$(fileout_section_footer false)"
    "$do_pretty_json" && FIRST_FINDING=true && (printf "%s%s\n" "$str" "$(fileout_json_section "$1")") >> "$JSONFILE"
    SECTION_FOOTER_NEEDED=true
}

# arg1: whether to end object too
fileout_section_footer() {
     "$do_pretty_json" && printf "\n                    ]" >> "$JSONFILE"
     "$do_pretty_json" && "$1" && echo -e "\n          }" >> "$JSONFILE"
     SECTION_FOOTER_NEEDED=false
}

fileout_json_print_parameter() {
     local parameter="$1"
     local filler="$2"
     local value="$3"
     local not_last="$4"
     local spaces=""

     "$do_json" && \
         spaces="              " || \
         spaces="                                "
     if [[ -n "$value" ]] || [[ "$parameter" == finding ]]; then
          printf "%s%s%s%s" "$spaces" "\"$parameter\"" "$filler" ": \"$value\"" >> "$JSONFILE"
          "$not_last" && printf ",\n" >> "$JSONFILE"
     fi
}

fileout_json_finding() {
     local target
     local finding="$3"
     local cve="$4"
     local cwe="$5"
     local hint="$6"

     if "$do_json"; then
          "$FIRST_FINDING" || echo -n "," >> "$JSONFILE"
          echo -e "         {"  >> "$JSONFILE"
          fileout_json_print_parameter "id" "           " "$1" true
          fileout_json_print_parameter "ip" "           " "$NODE/$NODEIP" true
          fileout_json_print_parameter "port" "         " "$PORT" true
          fileout_json_print_parameter "severity" "     " "$2" true
          fileout_json_print_parameter "cve" "          " "$cve" true
          fileout_json_print_parameter "cwe" "          " "$cwe" true
          "$GIVE_HINTS" && fileout_json_print_parameter "hint" "         " "$hint" true
          fileout_json_print_parameter "finding" "      " "$finding" false
          echo -e "\n          }" >> "$JSONFILE"
    fi
    if "$do_pretty_json"; then
        if [[ "$1" == service ]]; then
            if [[ $SERVER_COUNTER -gt 1 ]]; then
                echo "          ," >> "$JSONFILE"
            fi
            target="$NODE"
            $do_mx_all_ips && target="$URI"
            echo -e "          {
                    \"targetHost\"      : \"$target\",
                    \"ip\"              : \"$NODEIP\",
                    \"port\"            : \"$PORT\",
                    \"rDNS\"            : \"$rDNS\",
                    \"service\"         : \"$finding\"," >> "$JSONFILE"
            $do_mx_all_ips && echo -e "                    \"hostname\"        : \"$NODE\","  >> "$JSONFILE"
         else
             ("$FIRST_FINDING" && echo -n "                            {" >> "$JSONFILE") || echo -n ",{" >> "$JSONFILE"
             echo -e -n "\n"  >> "$JSONFILE"
             fileout_json_print_parameter "id" "           " "$1" true
             fileout_json_print_parameter "severity" "     " "$2" true
             fileout_json_print_parameter "cve" "          " "$cve" true
             fileout_json_print_parameter "cwe" "          " "$cwe" true
             "$GIVE_HINTS" && fileout_json_print_parameter "hint" "         " "$hint" true
             fileout_json_print_parameter "finding" "      " "$finding" false
             echo -e -n "\n                           }" >> "$JSONFILE"
         fi
    fi
}

##################### FILE FORMATTING #########################

fileout_pretty_json_banner() {
     local target

     if ! "$do_mass_testing"; then
        [[ -z "$NODE" ]] && parse_hn_port "${URI}"
        # NODE, URL_PATH, PORT, IPADDR and IP46ADDR is set now  --> wrong place
        target="$NODE"
        $do_mx_all_ips && target="$URI"
     fi

     echo -e "          \"Invocation\"  : \"$PROG_NAME $CMDLINE\",
          \"at\"          : \"$HNAME:$OPENSSL_LOCATION\",
          \"version\"     : \"$VERSION ${GIT_REL_SHORT:-$CVS_REL_SHORT} from $REL_DATE\",
          \"openssl\"     : \"$OSSL_NAME $OSSL_VER from $OSSL_BUILD_DATE\",
          \"startTime\"   : \"$START_TIME\",
          \"scanResult\"  : ["
}

fileout_banner() {
     if "$JSONHEADER"; then
          # "$do_json" &&                    # here we maybe should add a banner, too
          "$do_pretty_json" && (printf "%s\n" "$(fileout_pretty_json_banner)") >> "$JSONFILE"
     fi
}

fileout_separator() {
     if "$JSONHEADER"; then
          "$do_pretty_json" && echo "          ," >> "$JSONFILE"
          "$do_json" && echo -n "," >> "$JSONFILE"
     fi
}

fileout_footer() {
     if "$JSONHEADER"; then
          fileout_json_footer
     fi
     # CSV: no footer
     return 0
}

fileout_insert_warning() {
     # See #815. Make sure we don't mess up the JSON PRETTY format if we complain with a client side warning.
     # This should only be called if an *extra* warning will be printed (previously: 'fileout <extra_warning_ID> "WARN" '
     # arg1: json identifier,  arg2: normally "WARN",  arg3: finding
     #
     # Also, we have to be careful with any form of mass testing so that a warning won't lead to an invalid JSON
     # file. As any child will do any check as well (to be reconsidered later), we don't need also the parent to issue
     # warnings upfront, see #1169. As a detection we'll use --file/-iL as in the children jobs it'll be removed:
     [[ "$CMDLINE=" =~ --file ]] && return 0
     [[ "$CMDLINE=" =~ -iL ]] && return 0
     # Note we still have the message on screen + in HTML which is not as optimal as it could be

     if "$do_pretty_json"; then
          echo -e "          \"clientProblem${CLIENT_PROB_NO}\" : [" >>"$JSONFILE"
          CLIENT_PROB_NO=$((CLIENT_PROB_NO + 1))
          FIRST_FINDING=true       # make sure we don't have a comma here
     fi
     fileout "$1" "$2" "$3"
     if "$do_pretty_json"; then
          echo -e "\n          ]," >>"$JSONFILE"
     fi
}

fileout_csv_finding() {
     safe_echo "\"$1\"," >> "$CSVFILE"
     safe_echo "\"$2\"," >> "$CSVFILE"
     safe_echo "\"$3\"," >> "$CSVFILE"
     safe_echo "\"$4\"," >> "$CSVFILE"
     safe_echo "\"$5\"," >> "$CSVFILE"
     safe_echo "\"$6\"," >> "$CSVFILE"
     if "$GIVE_HINTS"; then
          safe_echo "\"$7\"," >> "$CSVFILE"
          safe_echo "\"$8\"\n" >> "$CSVFILE"
     else
          safe_echo "\"$7\"\n" >> "$CSVFILE"
     fi
}


# ID, SEVERITY, FINDING, CVE, CWE, HINT
fileout() {
     local severity="$2"
     local cve="$4"
     local cwe="$5"
     local hint="$6"

     if ( "$do_pretty_json" && [[ "$1" == service ]] ) || show_finding "$severity"; then
         local finding=$(strip_lf "$(newline_to_spaces "$(strip_quote "$3")")")           # additional quotes will mess up screen output
         [[ -e "$JSONFILE" ]] && [[ ! -d "$JSONFILE" ]] && fileout_json_finding "$1" "$severity" "$finding" "$cve" "$cwe" "$hint"
         "$do_csv" && [[ -n "$CSVFILE" ]] && [[ ! -d "$CSVFILE" ]] && \
               fileout_csv_finding "$1" "$NODE/$NODEIP" "$PORT" "$severity" "$finding" "$cve" "$cwe" "$hint"
     "$FIRST_FINDING" && FIRST_FINDING=false
     fi
}


json_header() {
     local fname_prefix
     local filename_provided=false

     [[ -n "$JSONFILE" ]] && [[ ! -d "$JSONFILE" ]] && filename_provided=true
     # Similar to HTML: Don't create headers and footers in the following scenarios:
     #  * no JSON/CSV output is being created.
     #  * mass testing is being performed and each test will have its own file.
     #  * this is an individual test within a mass test and all output is being placed in a single file.
     ! "$do_json" && ! "$do_pretty_json" && JSONHEADER=false && return 0
     "$do_mass_testing" && ! "$filename_provided" && JSONHEADER=false && return 0
     "$CHILD_MASS_TESTING" && "$filename_provided" && JSONHEADER=false && return 0

     if "$do_display_only"; then
          fname_prefix="local-ciphers"
     elif "$do_mass_testing"; then
          :
     elif "$do_mx_all_ips"; then
          fname_prefix="${FNAME_PREFIX}mx-${URI}"
     else
          # ensure NODE, URL_PATH, PORT, IPADDR and IP46ADDR are set
          ! "$filename_provided" && [[ -z "$NODE" ]] && parse_hn_port "${URI}"
          fname_prefix="${FNAME_PREFIX}${NODE}_p${PORT}"
     fi
     if [[ -z "$JSONFILE" ]]; then
          JSONFILE="$fname_prefix-$(date +"%Y%m%d-%H%M".json)"
     elif [[ -d "$JSONFILE" ]]; then
          JSONFILE="$JSONFILE/${fname_prefix}-$(date +"%Y%m%d-%H%M".json)"
     fi
     # Silently reset APPEND var if the file doesn't exist as otherwise it won't be created
     if "$APPEND" && [[ ! -s "$JSONFILE" ]]; then
          APPEND=false
     fi
     if "$APPEND"; then
          JSONHEADER=false
     else
          [[ -s "$JSONFILE" ]] && fatal "non-empty \"$JSONFILE\" exists. Either use \"--append\" or (re)move it" $ERR_FCREATE
          "$do_json" && echo "[" > "$JSONFILE"
          "$do_pretty_json" && echo "{" > "$JSONFILE"
     fi
     return 0
}


csv_header() {
     local fname_prefix
     local filename_provided=false

     [[ -n "$CSVFILE" ]] && [[ ! -d "$CSVFILE" ]] && filename_provided=true
     # CSV similar to JSON
     ! "$do_csv" && CSVHEADER=false && return 0
     "$do_mass_testing" && ! "$filename_provided" && CSVHEADER=false && return 0
     "$CHILD_MASS_TESTING" && "$filename_provided" && CSVHEADER=false && return 0

     if "$do_display_only"; then
          fname_prefix="local-ciphers"
     elif "$do_mass_testing"; then
          :
     elif "$do_mx_all_ips"; then
          fname_prefix="${FNAME_PREFIX}mx-${URI}"
     else
          # ensure NODE, URL_PATH, PORT, IPADDR and IP46ADDR are set
          ! "$filename_provided" && [[ -z "$NODE" ]] && parse_hn_port "${URI}"
          fname_prefix="${FNAME_PREFIX}${NODE}_p${PORT}"
     fi
     if [[ -z "$CSVFILE" ]]; then
          CSVFILE="${fname_prefix}-$(date +"%Y%m%d-%H%M".csv)"
     elif [[ -d "$CSVFILE" ]]; then
          CSVFILE="$CSVFILE/${fname_prefix}-$(date +"%Y%m%d-%H%M".csv)"
     fi
     # Silently reset APPEND var if the file doesn't exist as otherwise it won't be created
     if "$APPEND" && [[ ! -s "$CSVFILE" ]]; then
          APPEND=false
     fi
     if "$APPEND"; then
          CSVHEADER=false
     else
          [[ -s "$CSVFILE" ]] && fatal "non-empty \"$CSVFILE\" exists. Either use \"--append\" or (re)move it" $ERR_FCREATE
          touch "$CSVFILE"
          if "$GIVE_HINTS"; then
               fileout_csv_finding "id" "fqdn/ip" "port" "severity" "finding" "cve" "cwe" "hint"
          else
               fileout_csv_finding "id" "fqdn/ip" "port" "severity" "finding" "cve" "cwe"
          fi
     fi
     return 0
}


################# JSON FILE FORMATTING END. HTML START ####################

html_header() {
     local fname_prefix
     local filename_provided=false

     [[ -n "$HTMLFILE" ]] && [[ ! -d "$HTMLFILE" ]] && filename_provided=true
     # Don't create HTML headers and footers in the following scenarios:
     #  * HTML output is not being created.
     #  * mass testing is being performed and each test will have its own HTML file.
     #  * this is an individual test within a mass test and all HTML output is being placed in a single file.
     ! "$do_html" && HTMLHEADER=false && return 0
     "$do_mass_testing" && ! "$filename_provided" && HTMLHEADER=false && return 0
     "$CHILD_MASS_TESTING" && "$filename_provided" && HTMLHEADER=false && return 0

     if "$do_display_only"; then
          fname_prefix="local-ciphers"
     elif "$do_mass_testing"; then
          :
     elif "$do_mx_all_ips"; then
          fname_prefix="${FNAME_PREFIX}mx-${URI}"
     else
          # ensure NODE, URL_PATH, PORT, IPADDR and IP46ADDR are set
          ! "$filename_provided" && [[ -z "$NODE" ]] && parse_hn_port "${URI}"
          fname_prefix="${FNAME_PREFIX}${NODE}_p${PORT}"
     fi
     if [[ -z "$HTMLFILE" ]]; then
          HTMLFILE="$fname_prefix-$(date +"%Y%m%d-%H%M".html)"
     elif [[ -d "$HTMLFILE" ]]; then
          HTMLFILE="$HTMLFILE/$fname_prefix-$(date +"%Y%m%d-%H%M".html)"
     fi
     # Silently reset APPEND var if the file doesn't exist as otherwise it won't be created
     if "$APPEND" && [[ ! -s "$HTMLFILE" ]]; then
          APPEND=false
     fi
     if "$APPEND"; then
          HTMLHEADER=false
     else
          [[ -s "$HTMLFILE" ]] && fatal "non-empty \"$HTMLFILE\" exists. Either use \"--append\" or (re)move it" $ERR_FCREATE
          html_out "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
          html_out "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n"
          html_out "<!-- This file was created with testssl.sh. https://testssl.sh -->\n"
          html_out "<html xmlns=\"http://www.w3.org/1999/xhtml\">\n"
          html_out "<head>\n"
          html_out "<meta http-equiv=\"Content-Type\" content=\"application/xml+xhtml; charset=UTF-8\" />\n"
          html_out "<title>testssl.sh</title>\n"
          html_out "</head>\n"
          html_out "<body>\n"
          html_out "<pre>\n"
     fi
     return 0
}

html_banner() {
     if "$CHILD_MASS_TESTING" && "$HTMLHEADER"; then
          html_out "## Scan started as: \"$PROG_NAME $CMDLINE\"\n"
          html_out "## at $HNAME:$OPENSSL_LOCATION\n"
          html_out "## version testssl: $VERSION ${GIT_REL_SHORT:-$CVS_REL_SHORT} from $REL_DATE\n"
          html_out "## version openssl: \"$OSSL_NAME $OSSL_VER\" from \"$OSSL_BUILD_DATE\")\n\n"
     fi
}

html_footer() {
     if "$HTMLHEADER"; then
          html_out "</pre>\n"
          html_out "</body>\n"
          html_out "</html>\n"
     fi
     return 0
}

################# HTML FILE FORMATTING END ####################

prepare_logging() {
     # arg1: for testing mx records name we put a name of logfile in here, otherwise we get strange file names
     local fname_prefix="$1"
     local filename_provided=false

     [[ -n "$LOGFILE" ]] && [[ ! -d "$LOGFILE" ]] && filename_provided=true

     # Similar to html_header():
     ! "$do_logging" && return 0
     "$do_mass_testing" && ! "$filename_provided" && return 0
     "$CHILD_MASS_TESTING" && "$filename_provided" && return 0

     [[ -z "$fname_prefix" ]] && fname_prefix="${FNAME_PREFIX}${NODE}_p${PORT}"

     if [[ -z "$LOGFILE" ]]; then
          LOGFILE="$fname_prefix-$(date +"%Y%m%d-%H%M".log)"
     elif [[ -d "$LOGFILE" ]]; then
          # actually we were instructed to place all files in a DIR instead of the current working dir
          LOGFILE="$LOGFILE/$fname_prefix-$(date +"%Y%m%d-%H%M".log)"
     else
          : # just for clarity: a log file was specified, no need to do anything else
     fi

     if ! "$APPEND"; then
          [[ -s "$LOGFILE" ]] && fatal "non-empty \"$LOGFILE\" exists. Either use \"--append\" or (re)move it" $ERR_FCREATE
     fi
     tmln_out "## Scan started as: \"$PROG_NAME $CMDLINE\"" >>"$LOGFILE"
     tmln_out "## at $HNAME:$OPENSSL_LOCATION" >>"$LOGFILE"
     tmln_out "## version testssl: $VERSION ${GIT_REL_SHORT:-$CVS_REL_SHORT} from $REL_DATE" >>"$LOGFILE"
     tmln_out "## version openssl: \"$OSSL_VER\" from \"$OSSL_BUILD_DATE\")\n" >>"$LOGFILE"
     exec > >(tee -a -i "$LOGFILE")
}

################### FILE FORMATTING END #########################

###### START helper function definitions ######

if [[ "${BASH_VERSINFO[0]}" == 3 ]]; then
     # older bash can do this only (MacOS X), even SLES 11, see #697
     toupper() { tr 'a-z' 'A-Z' <<< "$1"; }
     tolower() { tr 'A-Z' 'a-z' <<< "$1"; }
else
     toupper() { echo -n "${1^^}"; }
     tolower() { echo -n "${1,,}"; }
fi

get_last_char() {
     echo "${1:~0}"      # "${string: -1}" would work too (both also in bash 3.2)
}
                         # Checking for last char. If already a separator supplied, we don't need an additional one
debugme() {
     [[ "$DEBUG" -ge 2 ]] && "$@"
     return 0
}

hex2dec() {
     echo $((16#$1))
}

# convert 414243 into ABC
hex2ascii() {
          for (( i=0; i<${#1}; i+=2 )); do
               # 2>/dev/null added because 'warning: command substitution: ignored null byte in input'
               # --> didn't help though
               printf "\x${1:$i:2}" 2>/dev/null
          done
}

# convert decimal number < 256 to hex
dec02hex() {
     printf "x%02x" "$1"
}

# convert decimal number between 256 and < 256*256 to hex
dec04hex() {
     local a=$(printf "%04x" "$1")
     printf "x%02s, x%02s" "${a:0:2}" "${a:2:2}"
}


# trim spaces for BSD and old sed
count_lines() {
     #echo "${$(wc -l <<< "$1")// /}"
     # ^^ bad substitution under bash, zsh ok. For some reason this does the trick:
     echo $(wc -l <<< "$1")
}

count_words() {
     #echo "${$(wc -w <<< "$1")// /}"
     # ^^ bad substitution under bash, zsh ok. For some reason this does the trick:
     echo $(wc -w <<< "$1")
}

count_ciphers() {
     echo $(wc -w <<< "${1//:/ }")
}

#arg1: TLS 1.2 and below ciphers
#arg2: TLS 1.3 ciphers
#arg3: options (e.g., -V)
actually_supported_ciphers() {
     local tls13_ciphers="$TLS13_OSSL_CIPHERS"

     [[ "$2" != "ALL" ]] && tls13_ciphers="$2"
     if "$HAS_CIPHERSUITES"; then
          $OPENSSL ciphers $3 $OSSL_CIPHERS_S -ciphersuites "$tls13_ciphers" "$1" 2>/dev/null || echo ""
     elif [[ -n "$tls13_ciphers" ]]; then
          $OPENSSL ciphers $3 $OSSL_CIPHERS_S "$tls13_ciphers:$1" 2>/dev/null || echo ""
     else
          $OPENSSL ciphers $OSSL_CIPHERS_S $3 "$1" 2>/dev/null || echo ""
     fi
}

# Given a protocol (arg1) and a list of ciphers (arg2) that is formatted as
# ", xx,xx, xx,xx, xx,xx, xx,xx" remove any TLSv1.3 ciphers if the protocol
# is less than 04 and remove any TLSv1.2-only ciphers if the protocol is less
# than 03.
strip_inconsistent_ciphers() {
     local -i proto=0x$1
     local cipherlist="$2"

     [[ $proto -lt 4 ]] && cipherlist="${cipherlist//, 13,0[0-9a-fA-F]/}"
     if [[ $proto -lt 3 ]]; then
          cipherlist="${cipherlist//, 00,3[b-fB-F]/}"
          cipherlist="${cipherlist//, 00,40/}"
          cipherlist="${cipherlist//, 00,6[7-9a-dA-D]/}"
          cipherlist="${cipherlist//, 00,9[c-fC-F]/}"
          cipherlist="${cipherlist//, 00,[abAB][0-9a-fA-F]/}"
          cipherlist="${cipherlist//, 00,[cC][0-5]/}"
          cipherlist="${cipherlist//, 16,[bB][7-9aA]/}"
          cipherlist="${cipherlist//, [cC]0,2[3-9a-fA-F]/}"
          cipherlist="${cipherlist//, [cC]0,3[01278a-fA-F]/}"
          cipherlist="${cipherlist//, [cC]0,[4-9aA][0-9a-fA-F]/}"
          cipherlist="${cipherlist//, [cC][cC],1[345]/}"
          cipherlist="${cipherlist//, [cC][cC],[aA][89a-eA-E]/}"
     fi
     echo "$cipherlist"
     return 0
}

newline_to_spaces() {
     tr '\n' ' ' <<< "$1" | sed 's/ $//'
}

colon_to_spaces() {
     echo "${1//:/ }"
}

strip_lf() {
     tr -d '\n' <<< "$1" | tr -d '\r'
}

strip_spaces() {
     echo "${1// /}"
}

# https://web.archive.org/web/20121022051228/http://codesnippets.joyent.com/posts/show/1816
strip_leading_space() {
     printf "%s" "${1#"${1%%[![:space:]]*}"}"
}
strip_trailing_space() {
     printf "%s" "${1%"${1##*[![:space:]]}"}"
}


# retrieve cipher from ServerHello (via openssl)
get_cipher() {
     local cipher=""
     local server_hello="$(cat -v "$1")"
     # This and two other following instances are not best practice and normally a useless use of "cat", see
     # https://web.archive.org/web/20160711205930/http://porkmail.org/era/unix/award.html#uucaletter
     # However there seem to be cases where the preferred  $(< "$1")  logic has a problem.
     # Esepcially with bash 3.2 (Mac OS X) and when on the server side binary chars
     # are returned, see https://stackoverflow.com/questions/7427262/how-to-read-a-file-into-a-variable-in-shell#22607352
     # and https://github.com/drwetter/testssl.sh/issues/1292
     # Performance measurements showed no to barely measureable penalty (1s displayed in 9 tries).

     if [[ "$server_hello" =~ Cipher\ *:\ ([A-Z0-9]+-[A-Za-z0-9\-]+|TLS_[A-Za-z0-9_]+) ]]; then
          cipher="${BASH_REMATCH##* }"
     elif [[ "$server_hello" =~ (New|Reused)", "(SSLv[23]|TLSv1(\.[0-3])?(\/SSLv3)?)", Cipher is "([A-Z0-9]+-[A-Za-z0-9\-]+|TLS_[A-Za-z0-9_]+) ]]; then
          cipher="${BASH_REMATCH##* }"
     fi
     tm_out "$cipher"
}

# retrieve protocol from ServerHello (via openssl)
get_protocol() {
     local protocol=""
     local server_hello="$(cat -v "$1")"

     if [[ "$server_hello" =~ Protocol\ *:\ (SSLv[23]|TLSv1(\.[0-3])?) ]]; then
          protocol="${BASH_REMATCH##* }"
     elif [[ "$server_hello" =~ (New|Reused)", TLSv1.3, Cipher is "TLS_[A-Z0-9_]+ ]]; then
          # Note: When OpenSSL prints "New, <protocol>, Cipher is <cipher>", <cipher> is the
          # negotiated cipher, but <protocol> is not the negotiated protocol. Instead, it is
          # the SSL/TLS protocol that first defined <cipher>. Since the ciphers that were
          # first defined for TLSv1.3 may only be used with TLSv1.3, this line may be used
          # to determine whether TLSv1.3 was negotiated, but if another protocol is specified
          # on this line, then this line does not indicate the actual protocol negotiated. Also,
          # only TLSv1.3 cipher suites have names that begin with TLS_, which provides additional
          # assurance that the above match will only succeed if TLSv1.3 was negotiated.
          protocol="TLSv1.3"
     fi
     tm_out "$protocol"
}

is_number() {
     [[ "$1" =~ ^[1-9][0-9]*$ ]] && \
          return 0 || \
          return 1
}

is_ipv4addr() {
     local octet="(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
     local ipv4address="$octet\\.$octet\\.$octet\\.$octet"

     [[ -z "$1" ]] && return 1
     # more than numbers, important for hosts like AAA.BBB.CCC.DDD.in-addr.arpa.DOMAIN.TLS
     [[ -n $(tr -d '0-9\.' <<< "$1") ]] && return 1

     grep -Eq "$ipv4address" <<< "$1" && \
          return 0 || \
          return 1
}

# a bit easier
is_ipv6addr() {
     [[ -z "$1" ]] && return 1
     # less than 2x ":"
     [[ $(count_lines "$(tr ':' '\n' <<< "$1")") -le 1 ]] && \
          return 1
     #check on chars allowed:
     [[ -n "$(tr -d '0-9:a-fA-F ' <<< "$1" | sed -e '/^$/d')" ]] && \
          return 1
     return 0
}

# now some function for the integrated BIGIP F5 Cookie detector (see https://github.com/drwetter/F5-BIGIP-Decoder)

f5_hex2ip() {
     debugme echo "$1"
     echo $((16#${1:0:2})).$((16#${1:2:2})).$((16#${1:4:2})).$((16#${1:6:2}))
}
f5_hex2ip6() {
     debugme echo "$1"
     echo "[${1:0:4}:${1:4:4}:${1:8:4}:${1:12:4}.${1:16:4}:${1:20:4}:${1:24:4}:${1:28:4}]"
}

f5_determine_routeddomain() {
     local tmp
     tmp="${1%%o*}"
     echo "${tmp/rd/}"
}

f5_ip_oldstyle() {
     local tmp
     local a b c d

     tmp="${1/%.*}"                     # until first dot
     tmp="$(printf "%08x" "$tmp")"       # convert the whole thing to hex, now back to ip (reversed notation:
     tmp="$(f5_hex2ip $tmp)"               # transform to ip with reversed notation
     IFS="." read -r a b c d <<< "$tmp" # reverse it
     echo $d.$c.$b.$a
}

f5_port_decode() {
     local tmp

     tmp="$(strip_lf "$1")"             # remove lf if there is one
     tmp="${tmp/.0000/}"                # to be sure remove trailing zeros with a dot
     tmp="${tmp#*.}"                    # get the port
     tmp="$(printf "%04x" "${tmp}")"    # to hex
     if [[ ${#tmp} -eq 4 ]]; then
          :
     elif [[ ${#tmp} -eq 3 ]]; then          # fill it up with leading zeros if needed
          tmp=0${tmp}
     elif [[ ${#tmp} -eq 2 ]]; then
          tmp=00${tmp}
     fi
     echo $((16#${tmp:2:2}${tmp:0:2}))  # reverse order and convert it from hex to dec
}



###### END helper function definitions ######

# prints out multiple lines in $1, left aligned by spaces in $2
out_row_aligned() {
     local first=true

     while read line; do
          "$first" && \
               first=false || \
               out "$2"
          outln "$line"
     done <<< "$1"
}

# prints text over multiple lines, trying to make no line longer than $max_width.
# Each line is indented with $spaces.
out_row_aligned_max_width() {
     local text="$1"
     local spaces="$2"
     local -i max_width="$3"
     local -i i len
     local cr=$'\n'
     local line
     local first=true

     max_width=$max_width-${#spaces}
     len=${#text}
     while true; do
          if [[ $len -lt $max_width ]]; then
               # If the remaining text to print is shorter than $max_width,
               # then just print it.
               i=$len
          else
               # Find the final space character in the text that is less than
               # $max_width characters into the remaining text, and make the
               # text up to that space character the next line to print.
               line="${text:0:max_width}"
               line="${line% *}"
               i="${#line}"
               if [[ $i -eq $max_width ]]; then
                    # If there are no space characters in the first $max_width
                    # characters of the remaining text, then make the text up
                    # to the first space the next line to print. If there are
                    # no space characters in the remaining text, make the
                    # remaining text the next line to print.
                    line="${text#* }"
                    i=$len-${#line}
                    [[ $i -eq 0 ]] && i=$len
               fi
          fi
          if ! "$first"; then
               tm_out "${cr}${spaces}"
          fi
          tm_out "${text:0:i}"
          [[ $i -eq $len ]] && break
          len=$len-$i-1
          i=$i+1
          text="${text:i:len}"
          first=false
          [[ $len -eq 0 ]] && break
     done
     return 0
}

out_row_aligned_max_width_by_entry() {
     local text="$1"
     local spaces="$2"
     local -i max_width="$3"
     local print_function="$4"
     local resp entry prev_entry=" "

     resp="$(out_row_aligned_max_width "$text" "$spaces" "$max_width")"
     while read -d " " entry; do
        if [[ -n "$entry" ]]; then
             $print_function "$entry"
        elif [[ -n "$prev_entry" ]]; then
             outln; out " "
        fi
        out " "
        prev_entry="$entry"
    done <<< "$resp"
}

print_fixed_width() {
     local text="$1"
     local -i i len width="$2"
     local print_function="$3"

     len=${#text}
     $print_function "$text"
     for (( i=len; i <= width; i++ )); do
          out " "
     done
}

# saves $TMPFILE or file supplied in $2 under name "$TEMPDIR/$NODEIP.$1".
# Note: after finishing $TEMPDIR will be removed unless DEBUG >=1
tmpfile_handle() {
     local savefile="$2"
     [[ -z "$savefile" ]] && savefile=$TMPFILE
#FIXME: make sure/find out if we do not need $TEMPDIR/$NODEIP.$1" if debug=0. We would save fs access here
     mv $savefile "$TEMPDIR/$NODEIP.$1" 2>/dev/null
     [[ $ERRFILE =~ dev.null ]] && return 0 || \
          mv $ERRFILE "$TEMPDIR/$NODEIP.${1//.txt/}.errorlog" 2>/dev/null
     return 0
}

# arg1: line with comment sign, tabs and so on
filter_input() {
     sed -e 's/#.*$//' -e '/^$/d' <<< "$1" | tr -d '\n' | tr -d '\t' | tr -d '\r'
}

# Dl's any URL (arg1) via HTTP 1.1 GET from port 80, arg2: file to store http body.
# Proxy is not honored yet (see cmd line switches) -- except when using curl or wget.
# There the environment variable is used automatically
# Currently it is being used by check_revocation_crl() only.
http_get() {
     local proto z
     local node="" query=""
     local dl="$2"
     local useragent="$UA_STD"
     local jsonID="http_get"

     "$SNEAKY" && useragent="$UA_SNEAKY"

     if type -p curl &>/dev/null; then
          if [[ -z "$PROXY" ]]; then
               curl -s --noproxy '*' -A $''"$useragent"'' -o $dl "$1"
          else
               # for the sake of simplicity assume the proxy is using http
               curl -s -x $PROXYIP:$PROXYPORT -A $''"$useragent"'' -o $dl "$1"
          fi
          return $?
     elif type -p wget &>/dev/null; then
          # wget has no proxy command line. We need to use http_proxy instead. And for the sake of simplicity
          # assume the GET protocol we query is using http -- http_proxy is the $ENV not for the connection TO
          # the proxy, but for the protocol we query THROUGH the proxy
          if [[ -z "$PROXY" ]]; then
               wget --no-proxy -q -U $''"$useragent"'' -O $dl "$1"
          else
               if [[ -z "$http_proxy" ]]; then
                    http_proxy=http://$PROXYIP:$PROXYPORT wget -q -U $''"$useragent"'' -O $dl "$1"
               else
                    wget -q -U $''"$useragent"'' -O $dl "$1"
               fi
          fi
          return $?
     else
          # Worst option: slower and hiccups with chunked transfers. Workaround for the
          # latter is using HTTP/1.0. We do not support https here, yet.
          # First the URL will be split
          IFS=/ read -r proto z node query <<< "$1"
          proto=${proto%:}
          if [[ "$proto" != http ]]; then
               pr_warning "protocol $proto not supported yet"
               fileout "$jsonID" "DEBUG" "protocol $proto not supported yet"
               return 6
          fi
          if [[ -n $PROXY ]]; then
               # PROXYNODE works better than PROXYIP on modern versions of squid. \
               # We don't reuse the code in fd_socket() as there's initial CONNECT which makes problems
               if ! exec 33<> /dev/tcp/${PROXYNODE}/${PROXYPORT}; then
                    outln
                    pr_warning "$PROG_NAME: unable to open a socket to proxy $PROXYNODE:$PROXYPORT"
                    fileout "$jsonID" "DEBUG" "$PROG_NAME: unable to open a socket to proxy $PROXYNODE:$PROXYPORT"
                    return 6
               else
                    printf -- "%b" "GET $proto://$node/$query HTTP/1.0\r\nUser-Agent: $useragent\r\nHost: $node\r\nAccept: */*\r\n\r\n" >&33
               fi
          else
               IFS=/ read -r proto z node query <<< "$1"
               exec 33<>/dev/tcp/$node/80
               printf -- "%b" "GET /$query HTTP/1.0\r\nUser-Agent: $useragent\r\nHost: $node\r\nAccept: */*\r\n\r\n" >&33
          fi
          # Strip HTTP header. When in Debug Mode we leave the raw data in place
          if [[ $DEBUG -ge 1 ]]; then
               cat <&33 >${dl}.raw
               cat ${dl}.raw | sed '1,/^[[:space:]]*$/d' >${dl}
          else
               cat <&33 | sed '1,/^[[:space:]]*$/d' >${dl}
          fi
          exec 33<&-
          exec 33>&-
          [[ -s "$dl" ]] && return 0 || return 1
     fi
}

# Outputs the headers when downloading any URL (arg1) via HTTP 1.1 GET from port 80.
# Only works if curl or wget is available.
# There the environment variable is used automatically
# Currently it is being used by check_pwnedkeys() only.
http_get_header() {
     local proto z
     local node="" query=""
     local dl="$2"
     local useragent="$UA_STD"
     local jsonID="http_get_header"
     local headers
     local -i ret

     "$SNEAKY" && useragent="$UA_SNEAKY"

     if type -p curl &>/dev/null; then
          if [[ -z "$PROXY" ]]; then
               headers="$(curl --head -s  --noproxy '*' -A $''"$useragent"'' "$1")"
          else
               # for the sake of simplicity assume the proxy is using http
               headers="$(curl --head -s -x $PROXYIP:$PROXYPORT -A $''"$useragent"'' "$1")"
          fi
          ret=$?
          [[ $ret -eq 0 ]] && tm_out "$headers"
          return $ret
     elif type -p wget &>/dev/null; then
          # wget has no proxy command line. We need to use http_proxy instead. And for the sake of simplicity
          # assume the GET protocol we query is using http -- http_proxy is the $ENV not for the connection TO
          # the proxy, but for the protocol we query THROUGH the proxy
          if [[ -z "$PROXY" ]]; then
                headers="$(wget --no-proxy -q -S -U $''"$useragent"'' -O /dev/null "$1" 2>&1)"
          else
               if [[ -z "$http_proxy" ]]; then
                    headers="$(http_proxy=http://$PROXYIP:$PROXYPORT wget -q -S  -U $''"$useragent"'' -O /dev/null "$1" 2>&1)"
               else
                    headers="$(wget -q -S -U $''"$useragent"'' -O /dev/null "$1" 2>&1)"
               fi
          fi
          ret=$?
          [[ $ret -eq 0 ]] && tm_out "$headers"
          # wget(1): "8: Server issued an error response.". Happens e.g. when 404 is returned. However also if the call wasn't correct (400)
          # So we assume for now that everything is submitted correctly. We parse the error code too later
          [[ $ret -eq 8 ]] && ret=0 && tm_out "$headers"
          return $ret
     else
          return 1
     fi
}

ldap_get() {
     local ldif
     local -i success
     local crl="$1"
     local tmpfile="$2"
     local jsonID="$3"

     if type -p curl &>/dev/null; then
          # proxy handling?
          ldif="$(curl -s "$crl")"
          [[ $? -eq 0 ]] || return 1
          awk '/certificateRevocationList/ { print $2 }' <<< "$ldif" | $OPENSSL base64 -d -A -out "$tmpfile" 2>/dev/null
          [[ -s "$tmpfile" ]] || return 1
          return 0
     else
          pr_litecyan " (for LDAP CRL check install \"curl\")"
          fileout "$jsonID" "INFO" "LDAP CRL revocation check needs \"curl\""
          return 2
     fi
}

# checks whether the public key in arg1 appears in the https://pwnedkeys.com/ database.
# arg1: file containing certificate
# arg2: public key algorithm
# arg3 key size
# Responses are as follows:
#     0 - not checked
#     1 - key not found in database
#     2 - key found in database
#     7 - network/proxy failure
check_pwnedkeys() {
     local cert="$1"
     local cert_key_algo="$2"
     local -i cert_keysize="$3"
     local pubkey curve response

     "$PHONE_OUT" || return 0

     # https://pwnedkeys.com only keeps records on 1024 bit and larger RSA keys,
     # as well as elliptic-curve keys on the P-256, P-384, and P-521 curves.
     if [[ "$cert_key_algo" =~ RSA ]] || [[ "$cert_key_algo" =~ rsa ]]; then
          [[ $cert_keysize -ge 1024 ]] || return 0
     elif [[ "$cert_key_algo" =~ ecdsa ]] || [[ "$cert_key_algo" == *ecPublicKey ]]; then
          [[ $cert_keysize -eq 256 ]] || [[ $cert_keysize -eq 384 ]] || \
               [[ $cert_keysize -eq 521 ]] || return 0
     else
          return 0
     fi

     pubkey="$($OPENSSL x509 -in "$cert" -pubkey -noout 2>/dev/null)"
     # If it is an elliptic curve key, check that it is P-256, P-384, or P-521.
     if [[ "$cert_key_algo" =~ ecdsa ]] || [[ "$cert_key_algo" == *ecPublicKey ]]; then
          curve="$($OPENSSL ec -pubin -text <<< "$pubkey" 2>/dev/null)"
          curve="${curve#*ASN1 OID: }"
          [[ "$curve" == prime256v1* ]] || [[ "$curve" == secp384r1* ]] || \
               [[ "$curve" == secp521r1* ]] || return 0
     fi
     fingerprint="$($OPENSSL pkey -pubin -outform DER <<< "$pubkey" 2>/dev/null | $OPENSSL dgst -sha256 -hex 2>/dev/null)"
     fingerprint="${fingerprint#*= }"
     response="$(http_get_header "https://v1.pwnedkeys.com/$fingerprint")"
     # Handle curl's/wget's connectivity exit codes
     case $? in
          4|5|7)     return 7 ;;
          1|2|3|6)   return 0 ;;
                     # unknown codes we just say "not checked"
     esac
     if [[ "$response" =~ "404 Not Found" ]]; then
          return 1
     elif [[ "$response" =~ "200 OK" ]]; then
          return 2
     else
          return 0
     fi
}

check_revocation_crl() {
     local crl="$1"
     local jsonID="$2"
     local tmpfile=""
     local scheme retcode
     local -i success

     "$PHONE_OUT" || return 0
     [[ -n "$GOOD_CA_BUNDLE" ]] || return 0
     scheme="$(tolower "${crl%%://*}")"
     # The code for obtaining CRLs only supports LDAP, HTTP, and HTTPS URLs.
     [[ "$scheme" == http ]] || [[ "$scheme" == https ]] || [[ "$scheme" == ldap ]] || return 0
     tmpfile=$TEMPDIR/${NODE}-${NODEIP}.${crl##*\/} || exit $ERR_FCREATE
     if [[ "$scheme" == ldap ]]; then
          ldap_get "$crl" "$tmpfile" "$jsonID"
          success=$?
     else
          http_get "$crl" "$tmpfile"
          success=$?
     fi
     if [[ $success -eq 2 ]]; then
          return 0
     elif [[ $success -ne 0 ]]; then
          out ", "
          pr_warning "retrieval of \"$crl\" failed"
          fileout "$jsonID" "WARN" "CRL retrieval from $crl failed"
          return 1
     fi
     # -crl_download could be more elegant but is supported from 1.0.2 onwards only
     $OPENSSL crl -inform DER -in "$tmpfile" -outform PEM -out "${tmpfile%%.crl}.pem" &>$ERRFILE
     if [[ $? -ne 0 ]]; then
          pr_warning "conversion of \"$tmpfile\" failed"
          fileout "$jsonID" "WARN" "conversion of CRL to PEM format failed"
          return 1
     fi
     if grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TEMPDIR/intermediatecerts.pem; then
          $OPENSSL verify -crl_check -CAfile <(cat $ADDITIONAL_CA_FILES "$GOOD_CA_BUNDLE" "${tmpfile%%.crl}.pem") -untrusted $TEMPDIR/intermediatecerts.pem $HOSTCERT &> "${tmpfile%%.crl}.err"
     else
          $OPENSSL verify -crl_check -CAfile <(cat $ADDITIONAL_CA_FILES "$GOOD_CA_BUNDLE" "${tmpfile%%.crl}.pem") $HOSTCERT &> "${tmpfile%%.crl}.err"
     fi
     if [[ $? -eq 0 ]]; then
          out ", "
          pr_svrty_good "not revoked"
          fileout "$jsonID" "OK" "not revoked"
     else
          retcode=$(awk '/error [1-9][0-9]? at [0-9]+ depth lookup:/ { if (!found) {print $2; found=1} }' "${tmpfile%%.crl}.err")
          if [[ "$retcode" == 23 ]]; then # see verify_retcode_helper()
               out ", "
               pr_svrty_critical "revoked"
               fileout "$jsonID" "CRITICAL" "revoked"
          else
               retcode="$(verify_retcode_helper "$retcode")"
               out " $retcode"
               retcode="${retcode#(}"
               retcode="${retcode%)}"
               fileout "$jsonID" "WARN" "$retcode"
               if [[ $DEBUG -ge 2 ]]; then
                    outln
                    cat "${tmpfile%%.crl}.err"
               fi
          fi
     fi
     return 0
}

check_revocation_ocsp() {
     local uri="$1"
     local stapled_response="$2"
     local jsonID="$3"
     local tmpfile=""
     local -i success
     local response=""
     local host_header=""

     "$PHONE_OUT" || [[ -n "$stapled_response" ]] || return 0
     [[ -n "$GOOD_CA_BUNDLE" ]] || return 0
     if [[ -n "$PROXY" ]] && ! "$IGN_OCSP_PROXY"; then
          # see #1106 and https://github.com/openssl/openssl/issues/6965
          out ", "
          pr_warning "revocation not tested as \"openssl ocsp\" doesn't support a proxy"
          fileout "$jsonID" "WARN" "Revocation not tested as openssl ocsp doesn't support a proxy"
          return 0
     fi
     grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TEMPDIR/intermediatecerts.pem || return 0
     tmpfile=$TEMPDIR/${NODE}-${NODEIP}.${uri##*\/} || exit $ERR_FCREATE
     if [[ -n "$stapled_response" ]]; then
          > "$TEMPDIR/stapled_ocsp_response.dd"
          asciihex_to_binary_file "$stapled_response" "$TEMPDIR/stapled_ocsp_response.dd"
          $OPENSSL ocsp -no_nonce -respin "$TEMPDIR/stapled_ocsp_response.dd" \
               -issuer $TEMPDIR/hostcert_issuer.pem -verify_other $TEMPDIR/intermediatecerts.pem \
               -CAfile <(cat $ADDITIONAL_CA_FILES "$GOOD_CA_BUNDLE") -cert $HOSTCERT -text &> "$tmpfile"
     else
          host_header=${uri##http://}
          host_header=${host_header%%/*}
          if [[ "$OSSL_NAME" =~ LibreSSL ]]; then
               host_header="-header Host ${host_header}"
          elif [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.0* ]] || [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.1* ]] || \
               [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 3.0.0* ]]; then
               host_header="-header Host=${host_header}"
          else
               host_header="-header Host ${host_header}"
          fi
          $OPENSSL ocsp -no_nonce ${host_header} -url "$uri" \
               -issuer $TEMPDIR/hostcert_issuer.pem -verify_other $TEMPDIR/intermediatecerts.pem \
               -CAfile <(cat $ADDITIONAL_CA_FILES "$GOOD_CA_BUNDLE") -cert $HOSTCERT -text &> "$tmpfile"
     fi
     if [[ $? -eq 0 ]] && grep -Fq "Response verify OK" "$tmpfile"; then
          response="$(grep -F "$HOSTCERT: " "$tmpfile")"
          response="${response#$HOSTCERT: }"
          response="${response%\.}"
          if [[ "$response" =~ "good" ]]; then
               out ", "
               pr_svrty_good "not revoked"
               fileout "$jsonID" "OK" "not revoked"
          elif [[ "$response" =~ "revoked" ]]; then
               out ", "
               pr_svrty_critical "revoked"
               fileout "$jsonID" "CRITICAL" "revoked"
          else
               out ", "
               pr_warning "error querying OCSP responder"
               fileout "$jsonID" "WARN" "$response"
               if [[ $DEBUG -ge 2 ]]; then
                    outln
                    cat "$tmpfile"
               else
                    out " ($response)"
               fi
          fi
     else
          [[ -s "$tmpfile" ]] || response="empty ocsp response"
          [[ -z "$response" ]] && response="$(awk '/Responder Error:/ { print $3 }' "$tmpfile")"
          [[ -z "$response" ]] && grep -Fq "Response Verify Failure" "$tmpfile" && response="unable to verify response"
          [[ -z "$response" ]] && response="$(awk -F':' '/Code/ { print $NF }' $tmpfile)"
          out ", "
          pr_warning "error querying OCSP responder"
          fileout "$jsonID" "WARN" "$response"
          if [[ $DEBUG -ge 2 ]]; then
               outln
               [[ -s "$tmpfile" ]] && cat "$tmpfile" || echo "empty ocsp response"
          elif [[ -n "$response" ]]; then
               out " ($response)"
          fi
     fi
}

wait_kill(){
     local pid=$1             # pid we wait for or kill
     local maxsleep=$2        # how long we wait before killing

     HAD_SLEPT=0
     while true; do
          if ! ps $pid >/dev/null ; then
               return 0       # process terminated before didn't reach $maxsleep
          fi
          [[ "$DEBUG" -ge 6 ]] && ps $pid
          sleep 1
          maxsleep=$((maxsleep - 1))
          HAD_SLEPT=$((HAD_SLEPT + 1))
          test $maxsleep -le 0 && break
     done                     # needs to be killed:
     kill $pid >&2 2>/dev/null
     wait $pid 2>/dev/null    # make sure pid terminated, see wait(1p)
     return 3                 # means killed
}

# parse_date date format input-format
if "$HAS_GNUDATE"; then  # Linux and NetBSD
     parse_date() {
          LC_ALL=C date -d "$1" "$2"
     }
elif "$HAS_FREEBSDDATE"; then # FreeBSD and OS X
     parse_date() {
          LC_ALL=C date -j -f "$3" "$2" "$1"
     }
elif "$HAS_OPENBSDDATE"; then
     parse_date() {
          # we just echo it as a conversion as we want it is not possible
          echo "$1"
     }
else
     parse_date() {
          LC_ALL=C date -j "$2" "$1"
     }
fi

# arg1: An ASCII-HEX string
# arg2: file name
# Append $arg1 in binary format to $arg2
asciihex_to_binary_file(){
     local string="$1"
     local file="$2"
     local -i len
     local -i i ip2 ip4 ip6 ip8 ip10 ip12 ip14
     local -i remainder

     len=${#string}
     [[ $len%2 -ne 0 ]] && return 1

     for (( i=0; i <= len-16 ; i=i+16 )); do
          ip2=$i+2; ip4=$i+4; ip6=$i+6; ip8=$i+8; ip10=$i+10; ip12=$i+12; ip14=$i+14
          printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}\x${string:ip6:2}\x${string:ip8:2}\x${string:ip10:2}\x${string:ip12:2}\x${string:ip14:2}" >> "$file"
     done

     ip2=$i+2; ip4=$i+4; ip6=$i+6; ip8=$i+8; ip10=$i+10; ip12=$i+12; ip14=$i+14
     remainder=$len-$i
     case $remainder in
           2) printf -- "\x${string:i:2}" >> "$file" ;;
           4) printf -- "\x${string:i:2}\x${string:ip2:2}" >> "$file" ;;
           6) printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}" >> "$file" ;;
           8) printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}\x${string:ip6:2}" >> "$file" ;;
          10) printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}\x${string:ip6:2}\x${string:ip8:2}" >> "$file" ;;
          12) printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}\x${string:ip6:2}\x${string:ip8:2}\x${string:ip10:2}" >> "$file" ;;
          14) printf -- "\x${string:i:2}\x${string:ip2:2}\x${string:ip4:2}\x${string:ip6:2}\x${string:ip8:2}\x${string:ip10:2}\x${string:ip12:2}" >> "$file" ;;
     esac
     return 0
}

# arg1: text string
# Output a comma-separated ASCII-HEX string representation of the input string.
string_to_asciihex() {
     local string="$1"
     local -i i eos
     local output=""

     eos=${#string}-1
     for (( i=0; i<eos; i++ )); do
          output+="$(printf "%02x," "'${string:i:1}")"
     done
     [[ -n "$string" ]] && output+="$(printf "%02x" "'${string:eos:1}")"
     tm_out "$output"
     return 0

}

# Adjust options to $OPENSSL s_client based on OpenSSL version and protocol version
s_client_options() {
     local options=" $1"
     local ciphers="notpresent" tls13_ciphers="notpresent"

     # Extract the TLSv1.3 ciphers and the non-TLSv1.3 ciphers
     if [[ " $options " =~ " -cipher " ]]; then
          ciphers="${options#* -cipher }"
          ciphers="${ciphers%% *}"
          options="${options//-cipher $ciphers/}"
          ciphers="${ciphers##\'}"
          ciphers="${ciphers%%\'}"
     fi
     if [[ " $options " =~ " -ciphersuites " ]]; then
          tls13_ciphers="${options#* -ciphersuites }"
          tls13_ciphers="${tls13_ciphers%% *}"
          options="${options//-ciphersuites $tls13_ciphers/}"
          tls13_ciphers="${tls13_ciphers##\'}"
          tls13_ciphers="${tls13_ciphers%%\'}"
          [[ "$tls13_ciphers" == ALL ]] && tls13_ciphers="$TLS13_OSSL_CIPHERS"
     fi

     # Don't include the -servername option for an SSLv2 or SSLv3 ClientHello.
     [[ -n "$SNI" ]] && [[ " $options " =~ \ -ssl[2|3]\  ]] && options="${options//$SNI/}"

     # The server_name extension should not be included in the ClientHello unless
     # the -servername option is provided. However, OpenSSL 1.1.1 will include the
     # server_name extension unless the -noservername option is provided. So, if
     # the command line doesn't include -servername and the -noservername option is
     # supported, then add -noservername to the options.
     "$HAS_NOSERVERNAME" && [[ ! " $options " =~ " -servername " ]] && options+=" -noservername"

     # Newer versions of OpenSSL have dropped support for the -no_ssl2 option, so
     # remove any -no_ssl2 option if the option isn't supported. (Since versions of
     # OpenSSL that don't support -no_ssl2 also don't support SSLv2, the option
     # isn't needed for these versions of OpenSSL.)
     ! "$HAS_NO_SSL2" && options="${options//-no_ssl2/}"

     # At least one server will fail under some circumstances if compression methods are offered.
     # So, only offer compression methods if necessary for the test. In OpenSSL 1.1.0 and
     # 1.1.1 compression is only offered if the "-comp" option is provided.
     # OpenSSL 1.0.0, 1.0.1, and 1.0.2 offer compression unless the "-no_comp" option is provided.
     # OpenSSL 0.9.8 does not support either the "-comp" or the "-no_comp" option.
     if [[ " $options " =~ " -comp " ]]; then
          # Compression is needed for the test. So, remove "-comp" if it isn't supported, but
          # otherwise make no changes.
          ! "$HAS_COMP" && options="${options//-comp/}"
     else
          # Compression is not needed. So, specify "-no_comp" if that option is supported.
          "$HAS_NO_COMP" && options+=" -no_comp"
     fi

     # If $OPENSSL is compiled with TLSv1.3 support and s_client is called without
     # specifying a protocol, but specifying a list of ciphers that doesn't include
     # any TLSv1.3 ciphers, then the command will always fail. So, if $OPENSSL supports
     # TLSv1.3 and a cipher list is provided, but no protocol is specified, then add
     # -no_tls1_3 if no TLSv1.3 ciphers are provided.
     if "$HAS_TLS13" && [[ "$ciphers" != notpresent ]] && \
          ( [[ "$tls13_ciphers" == notpresent ]] || [[ -z "$tls13_ciphers" ]] ) && \
          [[ ! " $options " =~ \ -ssl[2|3]\  ]] && \
          [[ ! " $options " =~ \ -tls1\  ]] && \
          [[ ! " $options " =~ \ -tls1_[1|2|3]\  ]]; then
          options+=" -no_tls1_3"
     fi

     if [[ "$ciphers" != notpresent ]] || [[ "$tls13_ciphers" != notpresent ]]; then
          if ! "$HAS_CIPHERSUITES"; then
               [[ "$ciphers" == notpresent ]] && ciphers=""
               [[ "$tls13_ciphers" == notpresent ]] && tls13_ciphers=""
               [[ -n "$ciphers" ]] && [[ -n "$tls13_ciphers" ]] && ciphers=":$ciphers"
               ciphers="$tls13_ciphers$ciphers"
               options+=" -cipher $ciphers"
          else
               if [[ "$ciphers" != notpresent ]] && [[ -n "$ciphers" ]]; then
                    options+=" -cipher $ciphers"
               fi
               if [[ "$tls13_ciphers" != notpresent ]] && [[ -n "$tls13_ciphers" ]]; then
                    options+=" -ciphersuites $tls13_ciphers"
               fi
          fi
     fi

     # OpenSSL's name for secp256r1 is prime256v1. So whenever we encounter this
     # (e.g. client simulations) we replace it with the name which OpenSSL understands
     # This shouldn't be needed. We have this here as a last resort
     if [[ "$1" =~ " -curves " ]]; then
          [[ "$1" =~ secp192r1 ]] && options="${options//secp192r1/prime192v1}"
          [[ "$1" =~ secp256r1 ]] && options="${options//secp256r1/prime256v1}"
     fi
     tm_out "$options"
}

###### check code starts here ######

# determines whether the port has an HTTP service running or not (plain TLS, no STARTTLS)
# arg1 could be the protocol determined as "working". IIS6 needs that
service_detection() {
     local -i was_killed

     if ! "$CLIENT_AUTH"; then
          # SNI is not standardized for !HTTPS but fortunately for other protocols s_client doesn't seem to care
          printf "$GET_REQ11" | $OPENSSL s_client $(s_client_options "$1 -quiet $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE &
          wait_kill $! $HEADER_MAXSLEEP
          was_killed=$?
          head $TMPFILE | grep -aq '^HTTP\/' && SERVICE=HTTP
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -waq "SMTP|ESMTP|Exim|IdeaSmtpServer|Kerio Connect|Postfix" && SERVICE=SMTP   # I know some overlap here
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -Ewaq "POP|Gpop|MailEnable POP3 Server|OK Dovecot|Cyrus POP3" && SERVICE=POP  # I know some overlap here
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -Ewaq "IMAP|IMAP4|Cyrus IMAP4IMAP4rev1|IMAP4REV1|Gimap" && SERVICE=IMAP       # I know some overlap here
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -aq FTP && SERVICE=FTP
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -Eaqi "jabber|xmpp" && SERVICE=XMPP
          [[ -z "$SERVICE" ]] && head $TMPFILE | grep -Eaqw "Jive News|InterNetNews|NNRP|INN|Kerio Connect|NNTP Service|Kerio MailServer|NNTP server" && SERVICE=NNTP
          # MongoDB port 27017 will respond to a GET request with a mocked HTTP response
          [[ "$SERVICE" == HTTP ]] && head $TMPFILE | grep -Eaqw "MongoDB" && SERVICE=MongoDB
          debugme head -50 $TMPFILE | sed -e '/<HTML>/,$d' -e '/<html>/,$d' -e '/<XML/,$d' -e '/<xml/,$d' -e '/<\?XML/,$d' -e '/<\?xml/,$d' -e '/<\!DOCTYPE/,$d' -e '/<\!doctype/,$d'
     fi

     out " Service detected:      $CORRECT_SPACES"
     jsonID="service"
     case $SERVICE in
          HTTP)
               out " $SERVICE"
               fileout "${jsonID}" "INFO" "$SERVICE"
               ;;
          IMAP|POP|SMTP|NNTP|MongoDB)
               out " $SERVICE, thus skipping HTTP specific checks"
               fileout "${jsonID}" "INFO" "$SERVICE, thus skipping HTTP specific checks"
               ;;
          *)   if "$CLIENT_AUTH"; then
                    out " certificate-based authentication => skipping all HTTP checks"
                    echo "certificate-based authentication => skipping all HTTP checks" >$TMPFILE
                    fileout "${jsonID}" "INFO" "certificate-based authentication => skipping all HTTP checks"
               else
                    out " Couldn't determine what's running on port $PORT"
                    if "$ASSUME_HTTP"; then
                         SERVICE=HTTP
                         out " -- ASSUME_HTTP set though"
                         fileout "${jsonID}" "DEBUG" "Couldn't determine service -- ASSUME_HTTP set"
                    else
                         out ", assuming no HTTP service => skipping all HTTP checks"
                         fileout "${jsonID}" "DEBUG" "Couldn't determine service, skipping all HTTP checks"
                    fi
               fi
               ;;
     esac

     outln "\n"
     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

# 1: counter variable
# 2: threshold for this variable
# 3: string for first occurrence of problem
# 4: string for repeated occurrence of problem
#
connectivity_problem() {
     if [[ $1 -lt $2 ]]; then
          if "$TLS13_ONLY" && ! "$HAS_TLS13"; then
               :
          else
               prln_warning " Oops: $3"
          fi
          return 0
     fi
     if [[ $1 -ge $2 ]]; then
          if [[ "$4" =~ openssl\ s_client\ connect ]] ; then
               fatal "$4" $ERR_CONNECT "Consider increasing MAX_OSSL_FAIL (currently: $2)"
          elif [[ "$4" =~ repeated\ TCP\ connect ]]; then
               fatal "$4" $ERR_CONNECT "Consider increasing MAX_SOCKET_FAIL (currently: $2)"
          fi
          fatal "$4" $ERR_CONNECT
     fi
}


#problems not handled: chunked
run_http_header() {
     local header
     local referer useragent
     local url redirect
     local jsonID="HTTP_status_code"
     local spaces="                            "

     HEADERFILE=$TEMPDIR/$NODEIP.http_header.txt
     if [[ $NR_HEADER_FAIL -eq 0 ]]; then
          # skip repeating this line if it's 2nd, 3rd,.. try
          outln; pr_headlineln " Testing HTTP header response @ \"$URL_PATH\" "
          outln
     fi
     if [[ $NR_HEADER_FAIL -ge $MAX_HEADER_FAIL ]]; then
          # signal to caller we have a problem
          return 1
     fi

     pr_bold " HTTP Status Code           "
     [[ -z "$1" ]] && url="/" || url="$1"
     if [[ "$SOCKETHEADER" == true ]]; then
          :
          #FIXME: would be great to complete the handshake and then e.g. tunnel HTTP over it
     else
          printf "$GET_REQ11" | $OPENSSL s_client $(s_client_options "$OPTIMAL_PROTO $BUGS -quiet -ign_eof -connect $NODEIP:$PORT $PROXY $SNI") >$HEADERFILE 2>$ERRFILE &
          wait_kill $! $HEADER_MAXSLEEP
          if [[ $? -eq 0 ]]; then
               # Issue HTTP GET again as it properly finished within $HEADER_MAXSLEEP and didn't hang.
               # Doing it again in the foreground to get an accurate header time
               printf "$GET_REQ11" | $OPENSSL s_client $(s_client_options "$OPTIMAL_PROTO $BUGS -quiet -ign_eof -connect $NODEIP:$PORT $PROXY $SNI") >$HEADERFILE 2>$ERRFILE
               NOW_TIME=$(date "+%s")
               HTTP_TIME=$(awk -F': ' '/^date:/ { print $2 }  /^Date:/ { print $2 }' $HEADERFILE)
               HAD_SLEPT=0
          else
               # 1st GET request hung and needed to be killed. Check whether it succeeded anyway:
               if grep -Eiaq "XML|HTML|DOCTYPE|HTTP|Connection" $HEADERFILE; then
                    # correct by seconds we slept, HAD_SLEPT comes from wait_kill()
                    NOW_TIME=$(($(date "+%s") - HAD_SLEPT))
                    HTTP_TIME=$(awk -F': ' '/^date:/ { print $2 }  /^Date:/ { print $2 }' $HEADERFILE)
               else
                    prln_warning " likely HTTP header requests failed (#lines: $(wc -l $HEADERFILE | awk '{ print $1 }'))"
                    [[ "$DEBUG" -lt 1 ]] & outln "Rerun with DEBUG>=1 and inspect $HEADERFILE\n"
                    fileout "HTTP_status_code" "WARN" "HTTP header request failed"
                    debugme cat $HEADERFILE
                    ((NR_HEADER_FAIL++))
               fi
          fi
     fi
     if [[ ! -s $HEADERFILE ]]; then
          ((NR_HEADER_FAIL++))
          if [[ $NR_HEADER_FAIL -ge $MAX_HEADER_FAIL ]]; then
               # Now, try to give a hint whether it would make sense to try with OpenSSL 1.1.0 or 1.1.1 instead
               if [[ $CURVES_OFFERED == X448 ]] && ! "$HAS_X448" ; then
                    generic_nonfatal "HTTP header was repeatedly zero due to missing X448 curve." "${spaces}OpenSSL 1.1.1 might help. Skipping complete HTTP header section."
               elif [[ $CURVES_OFFERED == X25519 ]] && ! "$HAS_X25519" ; then
                    generic_nonfatal "HTTP header was repeatedly zero due to missing X25519 curve." "${spaces}OpenSSL 1.1.0 might help. Skipping complete HTTP header section."
               elif [[ $CURVES_OFFERED =~ X25519 ]] && [[ $CURVES_OFFERED =~ X448 ]] && ! "$HAS_X25519" && ! "$HAS_X448"; then
                    generic_nonfatal "HTTP header was repeatedly zero due to missing X25519/X448 curves." "${spaces}OpenSSL >=1.1.0 might help. Skipping complete HTTP header section."
               else
                    # we could give more hints but these are the most likely cases
                    generic_nonfatal "HTTP header was repeatedly zero." "Skipping complete HTTP header section."
               fi
               KNOWN_OSSL_PROB=true
               return 1
          else
               pr_warning "HTTP header reply empty. "
               fileout "$jsonID" "WARN" "HTTP header reply empty"
          fi
     fi

     # Populate vars for HTTP time
     debugme echo "$NOW_TIME: $HTTP_TIME"

     # Quit on first empty line to catch 98% of the cases. Next pattern is there because the SEDs tested
     # so far seem not to be fine with header containing x0d x0a (CRLF) which is the usal case.
     # So we also trigger also on any sign on a single line which is not alphanumeric (plus _)
     sed -e '/^$/q' -e '/^[^a-zA-Z_0-9]$/q' $HEADERFILE >$HEADERFILE.tmp
     # Now to be more sure we delete from '<' or '{' maybe with a leading blank until the end
     sed -e '/^ *<.*$/d' -e '/^ *{.*$/d'  $HEADERFILE.tmp >$HEADERFILE
     debugme echo -e "---\n $(< $HEADERFILE) \n---"

     HTTP_STATUS_CODE=$(awk '/^HTTP\// { print $2 }' $HEADERFILE 2>>$ERRFILE)
     msg_thereafter=$(awk -F"$HTTP_STATUS_CODE" '/^HTTP\// { print $2 }' $HEADERFILE 2>>$ERRFILE)   # dirty trick to use the status code as a
     msg_thereafter=$(strip_lf "$msg_thereafter")                                                   # field separator, otherwise we need a loop with awk
     debugme echo "Status/MSG: $HTTP_STATUS_CODE $msg_thereafter"

     [[ -n "$HTTP_STATUS_CODE" ]] && out "  $HTTP_STATUS_CODE$msg_thereafter"
     case $HTTP_STATUS_CODE in
          301|302|307|308)
               redirect=$(grep -a '^Location' $HEADERFILE | sed 's/Location: //' | tr -d '\r\n')
               out ", redirecting to \""; pr_url "$redirect"; out "\""
               if [[ $redirect =~ http:// ]]; then
                    pr_svrty_high " -- Redirect to insecure URL (NOT ok)"
                    fileout "insecure_redirect" "HIGH" "Redirect to insecure URL: \"$redirect\""
               fi
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\")"
               ;;
          200|204|403|405)
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\")"
               ;;
          206)
               out " -- WHAT?"
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\") -- WHAT?"
               # partial content shouldn't happen
               ;;
          400)
               pr_cyan " (Hint: better try another URL)"
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\") -- better try another URL"
               ;;
          401)
               grep -aq "^WWW-Authenticate" $HEADERFILE && out "  "; out "$(strip_lf "$(grep -a "^WWW-Authenticate" $HEADERFILE)")"
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\") -- $(grep -a "^WWW-Authenticate" $HEADERFILE)"
               ;;
          404)
               out " (Hint: supply a path which doesn't give a \"$HTTP_STATUS_CODE$msg_thereafter\")"
               fileout "$jsonID" "INFO" "$HTTP_STATUS_CODE$msg_thereafter (\"$URL_PATH\")"
               ;;
          "")
               prln_warning "No HTTP status code."
               fileout "$jsonID" "WARN" "No HTTP status code"
               return 1
               ;;
          *)
               pr_warning ". Oh, didn't expect \"$HTTP_STATUS_CODE$msg_thereafter\""
               fileout "$jsonID" "WARN" "Unexpected $HTTP_STATUS_CODE$msg_thereafter @ \"$URL_PATH\""
               ;;
     esac
     outln

     # we don't call "tmpfile_handle ${FUNCNAME[0]}.txt" as we need the header file in other functions!
     return 0
}

# Borrowed from Glenn Jackman, see https://unix.stackexchange.com/users/4667/glenn-jackman
#
match_ipv4_httpheader() {
     local octet="(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
     local ipv4address="$octet\\.$octet\\.$octet\\.$octet"
     local whitelisted_header="pagespeed|page-speed|^Content-Security-Policy|^MicrosoftSharePointTeamServices|^X-OWA-Version|^Location|^Server: PRTG"
     local your_ip_msg="(check if it's your IP address or e.g. a cluster IP)"
     local result
     local first=true
     local spaces="                              "
     local count
     local jsonID="ipv4_in_header"
     local cwe="CWE-212"
     local cve=""

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi

     # Whitelist some headers as they are mistakenly identified as ipv4 address. Issues #158, #323. Also facebook has a CSP rule for 127.0.0.1
     if grep -Evai "$whitelisted_header" $HEADERFILE | grep -Eiq "$ipv4address"; then
          pr_bold " IPv4 address in header       "
          count=0
          while read line; do
               result="$(grep -E "$ipv4address" <<< "$line")"
               result=$(strip_lf "$result")
               if [[ -n "$result" ]]; then
                    if ! $first; then
                         out "$spaces"
                         your_ip_msg=""
                    else
                         first=false
                    fi
                    pr_svrty_medium "$result"
                    outln "\n$spaces$your_ip_msg"
                    fileout "$jsonID" "MEDIUM" "$result $your_ip_msg" "$cve" "$cwe"
               fi
               count=$count+1
          done < $HEADERFILE
     fi
}


run_http_date() {
     local difftime
     local spaces="                              "
     jsonID="HTTP_clock_skew"

     if [[ $SERVICE != "HTTP" ]] || "$CLIENT_AUTH"; then
          return 0
     fi
     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " HTTP clock skew              "
     if [[ -n "$HTTP_TIME" ]]; then
          HTTP_TIME="$(strip_lf "$HTTP_TIME")"
          if "$HAS_OPENBSDDATE"; then
               # we can't normalize the date under OpenBSD thus no subtraction is possible
               outln "remote: $HTTP_TIME"
               out "${spaces}local:  $(date)"
               fileout "$jsonID" "INFO" "$HTTP_TIME - $(date)"
          else
               HTTP_TIME="$(parse_date "$HTTP_TIME" "+%s" "%a, %d %b %Y %T %Z" 2>>$ERRFILE)"
               difftime=$((HTTP_TIME - NOW_TIME))
               [[ $difftime != "-"* ]] && [[ $difftime != "0" ]] && difftime="+$difftime"
               # process was killed, so we need to add an error
               [[ $HAD_SLEPT -ne 0 ]] && difftime="$difftime (± 1.5)"
               out "$difftime sec from localtime";
               fileout "$jsonID" "INFO" "$difftime seconds from localtime"
          fi
     else
          out "Got no HTTP time, maybe try different URL?";
          fileout "$jsonID" "INFO" "Got no HTTP time, maybe try different URL?"
     fi
     debugme tm_out ", epoch: $HTTP_TIME"
     outln
     match_ipv4_httpheader "$1"
     return 0
}


# HEADERFILE needs to contain the HTTP header (made sure by invoker)
# arg1: key=word to match
# arg2: hint for fileout() if double header
# arg3: indentation, i.e string w spaces
# arg4: whether we need a CR before "misconfiguration"
# returns:
#    0 if header not found
#    1-n nr of headers found, then in HEADERVALUE the first value from key
#
match_httpheader_key() {
     local key="$1"
     local spaces="$3"
     local first=$4
     local -i nr=0

     nr=$(grep -Eaicw "^ *$key:" $HEADERFILE)
     if [[ $nr -eq 0 ]]; then
          HEADERVALUE=""
          return 0
     elif [[ $nr -eq 1 ]]; then
          HEADERVALUE="$(grep -Eiaw "^ *$key:" $HEADERFILE)"
          HEADERVALUE="${HEADERVALUE#*:}"                        # remove leading part=key to colon
          HEADERVALUE="$(strip_lf "$HEADERVALUE")"
          HEADERVALUE="$(strip_leading_space "$HEADERVALUE")"
          "$first" || out "$spaces"
          return 1
     else
          "$first" || out "$spaces"
          pr_svrty_medium "misconfiguration: "
          pr_italic "$key"
          pr_svrty_medium " ${nr}x"
          outln " -- checking first one only"
          out "$spaces"
          HEADERVALUE="$(fgrep -Faiw "$key:" $HEADERFILE | head -1)"
          HEADERVALUE="${HEADERVALUE#*:}"
          HEADERVALUE="$(strip_lf "$HEADERVALUE")"
          HEADERVALUE="$(strip_leading_space "$HEADERVALUE")"
          [[ $DEBUG -ge 2 ]] && tm_italic "$HEADERVALUE" && tm_out "\n$spaces"
          fileout "${2}_multiple" "MEDIUM" "Multiple $2 headers. Using first header: $HEADERVALUE"
          return $nr
     fi
}

includeSubDomains() {
     if grep -aiqw includeSubDomains "$1"; then
          pr_svrty_good ", includeSubDomains"
          return 0
     else
          pr_litecyan ", just this domain"
          return 1
     fi
}

preload() {
     if grep -aiqw preload "$1"; then
          pr_svrty_good ", preload"
          return 0
     else
          return 1
     fi
}


run_hsts() {
     local hsts_age_sec
     local hsts_age_days
     local spaces="                              "
     local jsonID="HSTS"

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " Strict Transport Security    "
     match_httpheader_key "Strict-Transport-Security" "HSTS" "$spaces" "true"
     if [[ $? -ne 0 ]]; then
          echo "$HEADERVALUE" >$TMPFILE
          hsts_age_sec=$(sed -e 's/[^0-9]*//g' <<< $HEADERVALUE)
          debugme echo "hsts_age_sec: $hsts_age_sec"
          if [[ -n $hsts_age_sec ]]; then
               hsts_age_days=$(( hsts_age_sec / 86400))
          else
               hsts_age_days=-1
          fi
          if [[ $hsts_age_days -eq -1 ]]; then
               pr_svrty_medium "misconfiguration: HSTS max-age (recommended > 15552000 seconds = 180 days ) is required but missing"
               fileout "${jsonID}_time" "MEDIUM" "misconfiguration, parameter max-age (recommended > 15552000 seconds = 180 days) missing"
          elif [[ $hsts_age_sec -eq 0 ]]; then
               pr_svrty_low "HSTS max-age is set to 0. HSTS is disabled"
               fileout "${jsonID}_time" "LOW" "0. HSTS is disabled"
          elif [[ $hsts_age_sec -gt $HSTS_MIN ]]; then
               pr_svrty_good "$hsts_age_days days" ; out "=$hsts_age_sec s"
               fileout "${jsonID}_time" "OK" "$hsts_age_days days (=$hsts_age_sec seconds) > $HSTS_MIN seconds"
          else
               pr_svrty_medium "$hsts_age_sec s = $hsts_age_days days is too short ( >=$HSTS_MIN seconds recommended)"
               fileout "${jsonID}_time" "MEDIUM" "max-age too short. $hsts_age_days days (=$hsts_age_sec seconds) < $HSTS_MIN seconds"
          fi
          if includeSubDomains "$TMPFILE"; then
               fileout "${jsonID}_subdomains" "OK" "includes subdomains"
          else
               fileout "${jsonID}_subdomains" "INFO" "only for this domain"
          fi
          if preload "$TMPFILE"; then
               fileout "${jsonID}_preload" "OK" "domain IS marked for preloading"
          else
               fileout "${jsonID}_preload" "INFO" "domain is NOT marked for preloading"
               #FIXME: To be checked against preloading lists,
               # e.g. https://dxr.mozilla.org/mozilla-central/source/security/manager/boot/src/nsSTSPreloadList.inc
               #      https://chromium.googlesource.com/chromium/src/+/master/net/http/transport_security_state_static.json
          fi
     else
          pr_svrty_low "not offered"
          fileout "$jsonID" "LOW" "not offered"
     fi
     outln

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


run_hpkp() {
     local -i hpkp_age_sec
     local -i hpkp_age_days
     local -i hpkp_nr_keys
     local hpkp_spki hpkp_spki_hostcert
     local -a backup_spki
     local spaces="                             "
     local spaces_indented="                  "
     local certificate_found=false
     local -i i nrsaved
     local first_hpkp_header
     local spki
     local ca_hashes="$TESTSSL_INSTALL_DIR/etc/ca_hashes.txt"

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " Public Key Pinning           "
     grep -aiw '^Public-Key-Pins' $HEADERFILE >$TMPFILE                    # TMPFILE includes report-only
     if [[ $? -eq 0 ]]; then
          if [[ $(grep -aciw '^Public-Key-Pins:' $TMPFILE) -gt 1 ]]; then
               pr_svrty_medium "Misconfiguration, multiple Public-Key-Pins headers"
               outln ", taking first line"
               fileout "HPKP_error" "MEDIUM" "multiple Public-Key-Pins in header"
               first_hpkp_header="$(grep -aiw '^Public-Key-Pins:' $TMPFILE | head -1)"
               # we only evaluate the keys here, unless they a not present
               out "$spaces "
          elif [[ $(grep -aciw '^Public-Key-Pins-Report-Only:' $TMPFILE) -gt 1 ]]; then
               outln "Multiple HPKP headers (Report-Only), taking first line"
               fileout "HPKP_notice" "INFO" "multiple Public-Key-Pins-Report-Only in header"
               first_hpkp_header="$(grep -aiw '^Public-Key-Pins-Report-Only:' $TMPFILE | head -1)"
               out "$spaces "
          elif [[ $(grep -Eaciw '^Public-Key-Pins:|^Public-Key-Pins-Report-Only:' $TMPFILE) -eq 2 ]]; then
               outln "Public-Key-Pins + Public-Key-Pins-Report-Only detected. Continue with first one"
               first_hpkp_header="$(grep -aiw '^Public-Key-Pins:' $TMPFILE)"
               out "$spaces "
          elif [[ $(grep -aciw '^Public-Key-Pins:' $TMPFILE) -eq 1 ]]; then
               first_hpkp_header="$(grep -aiw '^Public-Key-Pins:' $TMPFILE)"
          else
               outln "Public-Key-Pins-Only detected"
               first_hpkp_header="$(grep -aiw '^Public-Key-Pins-Report-Only:' $TMPFILE)"
               out "$spaces "
               fileout "HPKP_SPKIs" "INFO" "Only Public-Key-Pins-Report-Only"
          fi

          # remove leading Public-Key-Pins* and convert it to multiline arg
          sed -e 's/Public-Key-Pins://g' -e s'/Public-Key-Pins-Report-Only://' <<< "$first_hpkp_header" | \
               tr ';' '\n' | sed -e 's/\"//g' -e 's/^ //' >$TMPFILE

          hpkp_nr_keys=$(grep -ac pin-sha $TMPFILE)
          if [[ $hpkp_nr_keys -eq 1 ]]; then
               pr_svrty_high "Only one key pinned (NOT ok), means the site may become unavailable in the future, "
               fileout "HPKP_SPKIs" "HIGH" "Only one key pinned"
          else
               pr_svrty_good "$hpkp_nr_keys"
               out " keys, "
               fileout "HPKP_SPKIs" "OK" "$hpkp_nr_keys keys pinned in header"
          fi

          # print key=value pair with awk, then strip non-numbers, to be improved with proper parsing of key-value with awk
          if "$HAS_SED_E"; then
               hpkp_age_sec=$(awk -F= '/max-age/{max_age=$2; print max_age}' $TMPFILE | sed -E 's/[^[:digit:]]//g')
          else
               hpkp_age_sec=$(awk -F= '/max-age/{max_age=$2; print max_age}' $TMPFILE | sed -r 's/[^[:digit:]]//g')
          fi
          hpkp_age_days=$((hpkp_age_sec / 86400))
          if [[ $hpkp_age_sec -ge $HPKP_MIN ]]; then
               pr_svrty_good "$hpkp_age_days days" ; out "=$hpkp_age_sec s"
               fileout "HPKP_age" "OK" "HPKP age is set to $hpkp_age_days days ($hpkp_age_sec sec)"
          else
               out "$hpkp_age_sec s = "
               pr_svrty_medium "$hpkp_age_days days (< $HPKP_MIN s = $((HPKP_MIN / 86400)) days is not good enough)"
               fileout "HPKP_age" "MEDIUM" "age is set to $hpkp_age_days days ($hpkp_age_sec sec) < $HPKP_MIN s = $((HPKP_MIN / 86400)) days is not good enough."
          fi

          if includeSubDomains "$TMPFILE"; then
               fileout "HPKP_subdomains" "INFO" "is valid for subdomains as well"
          else
               fileout "HPKP_subdomains" "INFO" "is valid for this domain only"
          fi
          if preload "$TMPFILE"; then
               fileout "HPKP_preload" "INFO" "IS marked for browser preloading"
          else
               fileout "HPKP_preload" "INFO" "NOT marked for browser preloading"
          fi

          # Get the SPKIs first
          spki=$(tr ';' '\n' < $TMPFILE | tr -d ' ' | tr -d '\"' | awk -F'=' '/pin.*=/ { print $2 }')
          debugme tmln_out "\n$spki"

          # Look at the host certificate first
          if [[ ! -s "$HOSTCERT" ]]; then
               get_host_cert || return 1
               # no host certificate
          fi

          hpkp_spki_hostcert="$($OPENSSL x509 -in $HOSTCERT -pubkey -noout 2>/dev/null | grep -v PUBLIC | \
               $OPENSSL base64 -d 2>/dev/null | $OPENSSL dgst -sha256 -binary 2>/dev/null | $OPENSSL base64 2>/dev/null)"
          hpkp_ca="$($OPENSSL x509 -in $HOSTCERT -issuer -noout 2>/dev/null |sed 's/^.*CN=//' | sed 's/\/.*$//')"

          # Get keys/hashes from intermediate certificates
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS $PROXY -showcerts -connect $NODEIP:$PORT $SNI")  </dev/null >$TMPFILE 2>$ERRFILE
          # Place the server's certificate in $HOSTCERT and any intermediate
          # certificates that were provided in $TEMPDIR/intermediatecerts.pem
          # http://backreference.org/2010/05/09/ocsp-verification-with-openssl/
          awk -v n=-1 "/Certificate chain/ {start=1}
                  /-----BEGIN CERTIFICATE-----/{ if (start) {inc=1; n++} }
                  inc { print > (\"$TEMPDIR/level\" n \".crt\") }
                  /---END CERTIFICATE-----/{ inc=0 }" $TMPFILE
          nrsaved=$(count_words "$(echo $TEMPDIR/level?.crt 2>/dev/null)")
          rm $TEMPDIR/level0.crt 2>/dev/null

          printf ""> "$TEMPDIR/intermediate.hashes"
          if [[ $nrsaved -ge 2 ]]; then
               for cert_fname in $TEMPDIR/level?.crt; do
                    hpkp_spki_ca="$($OPENSSL x509 -in "$cert_fname" -pubkey -noout 2>/dev/null | grep -v PUBLIC | $OPENSSL base64 -d 2>/dev/null |
                         $OPENSSL dgst -sha256 -binary 2>/dev/null | $OPENSSL enc -base64 2>/dev/null)"
                    hpkp_name="$(get_cn_from_cert $cert_fname)"
                    hpkp_ca="$($OPENSSL x509 -in $cert_fname -issuer -noout 2>/dev/null |sed 's/^.*CN=//' | sed 's/\/.*$//')"
                    [[ -n $hpkp_name ]] || hpkp_name=$($OPENSSL x509 -in "$cert_fname" -subject -noout 2>/dev/null | sed 's/^subject= //')
                    echo "$hpkp_spki_ca $hpkp_name" >> "$TEMPDIR/intermediate.hashes"
               done
          fi

          # This is where the matching magic starts. First host, intermediate, then root certificate from the supplied stores
          spki_match=false
          has_backup_spki=false
          i=0
          for hpkp_spki in $spki; do
               certificate_found=false
               # compare collected SPKIs against the host certificate
               if [[ "$hpkp_spki_hostcert" == "$hpkp_spki" ]] || [[ "$hpkp_spki_hostcert" == "$hpkp_spki=" ]]; then
                    certificate_found=true       # We have a match
                    spki_match=true
                    out "\n$spaces_indented Host cert: "
                    pr_svrty_good "$hpkp_spki"
                    fileout "HPKP_$hpkp_spki" "OK" "SPKI $hpkp_spki matches the host certificate"
               fi
               debugme tm_out "\n  $hpkp_spki | $hpkp_spki_hostcert"

               # Check for intermediate match
               if ! "$certificate_found"; then
                    hpkp_matches=$(grep "$hpkp_spki" $TEMPDIR/intermediate.hashes 2>/dev/null)
                    if [[ -n $hpkp_matches ]]; then    # hpkp_matches + hpkp_spki + '='
                         # We have a match
                         certificate_found=true
                         spki_match=true
                         out "\n$spaces_indented Sub CA:    "
                         pr_svrty_good "$hpkp_spki"
                         ca_cn="$(sed "s/^[a-zA-Z0-9\+\/]*=* *//" <<< $"$hpkp_matches" )"
                         pr_italic " $ca_cn"
                         fileout "HPKP_$hpkp_spki" "OK" "SPKI $hpkp_spki matches Intermediate CA \"$ca_cn\" pinned in the HPKP header"
                    fi
               fi

               # we compare now against a precompiled list of SPKIs against the ROOT CAs we have in $ca_hashes
               if ! "$certificate_found"; then
                    hpkp_matches=$(grep -h "$hpkp_spki" $ca_hashes 2>/dev/null | sort -u)
                    if [[ -n $hpkp_matches ]]; then
                         certificate_found=true      # root CA found
                         spki_match=true
                         if [[ $(count_lines "$hpkp_matches") -eq 1 ]]; then
                              # replace by awk
                              match_ca=$(sed "s/[a-zA-Z0-9\+\/]*=* *//" <<< "$hpkp_matches")
                         else
                              match_ca=""

                         fi
                         ca_cn="$(sed "s/^[a-zA-Z0-9\+\/]*=* *//" <<< $"$hpkp_matches" )"
                         if [[ "$match_ca" == "$hpkp_ca" ]]; then          # part of the chain
                              out "\n$spaces_indented Root CA:   "
                              pr_svrty_good "$hpkp_spki"
                              pr_italic " $ca_cn"
                              fileout "HPKP_$hpkp_spki" "INFO" "SPKI $hpkp_spki matches Root CA \"$ca_cn\" pinned. (Root CA part of the chain)"
                         else                                              # not part of chain
                              match_ca=""
                              has_backup_spki=true                         # Root CA outside the chain --> we save it for unmatched
                              fileout "HPKP_$hpkp_spki" "INFO" "SPKI $hpkp_spki matches Root CA \"$ca_cn\" pinned. (Root backup SPKI)"
                              backup_spki[i]="$(strip_lf "$hpkp_spki")"    # save it for later
                              backup_spki_str[i]="$ca_cn"                  # also the name=CN of the root CA
                              i=$((i + 1))
                         fi
                    fi
               fi

               # still no success --> it's probably a backup SPKI
               if ! "$certificate_found"; then
                    # Most likely a backup SPKI, unfortunately we can't tell for what it is: host, intermediates
                    has_backup_spki=true
                    backup_spki[i]="$(strip_lf "$hpkp_spki")"     # save it for later
                    backup_spki_str[i]=""                        # no root ca
                    i=$((i + 1))
                    fileout "HPKP_$hpkp_spki" "INFO" "SPKI $hpkp_spki doesn't match anything. This is ok for a backup for any certificate"
                    # CSV/JSON output here for the sake of simplicity, rest we do en bloc below
               fi
          done

          # now print every backup spki out we saved before
          out "\n$spaces_indented Backups:   "

          # for i=0 manually do the same as below as there's other indentation here
          if [[ -n "${backup_spki_str[0]}" ]]; then
               pr_svrty_good "${backup_spki[0]}"
               #out " Root CA: "
               prln_italic " ${backup_spki_str[0]}"
          else
               outln "${backup_spki[0]}"
          fi
          # now for i=1
          for ((i=1; i < ${#backup_spki[@]} ;i++ )); do
               if [[ -n "${backup_spki_str[i]}" ]]; then
                    # it's a Root CA outside the chain
                    pr_svrty_good "$spaces_indented            ${backup_spki[i]}"
                    #out " Root CA: "
                    prln_italic " ${backup_spki_str[i]}"
               else
                    outln "$spaces_indented            ${backup_spki[i]}"
               fi
          done
          if [[ ! -f "$ca_hashes" ]] && "$spki_match"; then
               out "$spaces "
               prln_warning "Attribution of further hashes couldn't be done as $ca_hashes could not be found"
               fileout "HPKP_SPKImatch" "WARN" "Attribution of further hashes possible as $ca_hashes could not be found"
          fi

          # If all else fails...
          if ! "$spki_match"; then
               "$has_backup_spki" && out "$spaces"       # we had a few lines with backup SPKIs already
               prln_svrty_high " No matching key for SPKI found "
               fileout "HPKP_SPKImatch" "HIGH" "None of the SPKI match your host certificate, intermediate CA or known root CAs. Bricked site?"
          fi

          if ! "$has_backup_spki"; then
               prln_svrty_high " No backup keys found. Loss/compromise of the currently pinned key(s) will lead to bricked site. "
               fileout "HPKP_backup" "HIGH" "No backup keys found. Loss/compromise of the currently pinned key(s) will lead to bricked site."
          fi
     else
          outln "--"
          fileout "HPKP" "INFO" "No support for HTTP Public Key Pinning"
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

emphasize_stuff_in_headers(){
     local html_brown="<span style=\\\"color:olive;\\\">"
     local html_yellow="<span style=\\\"color:olive;font-weight:bold;\\\">"
     local html_off="<\\/span>"

# see http://www.grymoire.com/Unix/Sed.html#uh-3
#    outln "$1" | sed "s/[0-9]*/$brown&${off}/g"
     tmln_out "$1" | sed -e "s/\([0-9]\)/${brown}\1${off}/g" \
          -e "s/Unix/${yellow}Unix${off}/g" \
          -e "s/Debian/${yellow}Debian${off}/g" \
          -e "s/Win32/${yellow}Win32${off}/g" \
          -e "s/Win64/${yellow}Win64${off}/g" \
          -e "s/Ubuntu/${yellow}Ubuntu${off}/g" \
          -e "s/ubuntu/${yellow}ubuntu${off}/g" \
          -e "s/buster/${yellow}buster${off}/g" \
          -e "s/stretch/${yellow}stretch${off}/g" \
          -e "s/jessie/${yellow}jessie${off}/g" \
          -e "s/squeeze/${yellow}squeeze${off}/g" \
          -e "s/wheezy/${yellow}wheezy${off}/g" \
          -e "s/lenny/${yellow}lenny${off}/g" \
          -e "s/SUSE/${yellow}SUSE${off}/g" \
          -e "s/Red Hat Enterprise Linux/${yellow}Red Hat Enterprise Linux${off}/g" \
          -e "s/Red Hat/${yellow}Red Hat${off}/g" \
          -e "s/CentOS/${yellow}CentOS${off}/g" \
          -e "s/Via/${yellow}Via${off}/g" \
          -e "s/X-Forwarded/${yellow}X-Forwarded${off}/g" \
          -e "s/Liferay-Portal/${yellow}Liferay-Portal${off}/g" \
          -e "s/X-Cache-Lookup/${yellow}X-Cache-Lookup${off}/g" \
          -e "s/X-Cache/${yellow}X-Cache${off}/g" \
          -e "s/X-Squid/${yellow}X-Squid${off}/g" \
          -e "s/X-Server/${yellow}X-Server${off}/g" \
          -e "s/X-Varnish/${yellow}X-Varnish${off}/g" \
          -e "s/X-OWA-Version/${yellow}X-OWA-Version${off}/g" \
          -e "s/MicrosoftSharePointTeamServices/${yellow}MicrosoftSharePointTeamServices${off}/g" \
          -e "s/X-Application-Context/${yellow}X-Application-Context${off}/g" \
          -e "s/X-Version/${yellow}X-Version${off}/g" \
          -e "s/X-Powered-By/${yellow}X-Powered-By${off}/g" \
          -e "s/X-UA-Compatible/${yellow}X-UA-Compatible${off}/g" \
          -e "s/Link/${yellow}Link${off}/g" \
          -e "s/X-Rack-Cache/${yellow}X-Rack-Cache${off}/g" \
          -e "s/X-Runtime/${yellow}X-Runtime${off}/g" \
          -e "s/X-Pingback/${yellow}X-Pingback${off}/g" \
          -e "s/X-Permitted-Cross-Domain-Policies/${yellow}X-Permitted-Cross-Domain-Policies${off}/g" \
          -e "s/X-AspNet-Version/${yellow}X-AspNet-Version${off}/g" \
          -e "s/x-note/${yellow}x-note${off}/g" \
          -e "s/x-global-transaction-id/${yellow}x-global-transaction-id${off}/g" \
          -e "s/X-Global-Transaction-ID/${yellow}X-Global-Transaction-ID${off}/g" \
          -e "s/Alt-Svc/${yellow}Alt-Svc${off}/g" \
          -e "s/system-wsgw-management-loopback/${yellow}system-wsgw-management-loopback${off}/g"

     if "$do_html"; then
          if [[ $COLOR -ge 2 ]]; then
               html_out "$(tm_out "$1" | sed -e 's/\&/\&amp;/g' \
                    -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" \
                    -e "s/\([0-9]\)/${html_brown}\1${html_off}/g" \
                    -e "s/Unix/${html_yellow}Unix${html_off}/g" \
                    -e "s/Debian/${html_yellow}Debian${html_off}/g" \
                    -e "s/Win32/${html_yellow}Win32${html_off}/g" \
                    -e "s/Win64/${html_yellow}Win64${html_off}/g" \
                    -e "s/Ubuntu/${html_yellow}Ubuntu${html_off}/g" \
                    -e "s/ubuntu/${html_yellow}ubuntu${html_off}/g" \
                    -e "s/buster/${html_yellow}buster${html_off}/g" \
                    -e "s/stretch/${html_yellow}stretch${html_off}/g" \
                    -e "s/jessie/${html_yellow}jessie${html_off}/g" \
                    -e "s/squeeze/${html_yellow}squeeze${html_off}/g" \
                    -e "s/wheezy/${html_yellow}wheezy${html_off}/g" \
                    -e "s/lenny/${html_yellow}lenny${html_off}/g" \
                    -e "s/SUSE/${html_yellow}SUSE${html_off}/g" \
                    -e "s/Red Hat Enterprise Linux/${html_yellow}Red Hat Enterprise Linux${html_off}/g" \
                    -e "s/Red Hat/${html_yellow}Red Hat${html_off}/g" \
                    -e "s/CentOS/${html_yellow}CentOS${html_off}/g" \
                    -e "s/Via/${html_yellow}Via${html_off}/g" \
                    -e "s/X-Forwarded/${html_yellow}X-Forwarded${html_off}/g" \
                    -e "s/Liferay-Portal/${html_yellow}Liferay-Portal${html_off}/g" \
                    -e "s/X-Cache-Lookup/${html_yellow}X-Cache-Lookup${html_off}/g" \
                    -e "s/X-Cache/${html_yellow}X-Cache${html_off}/g" \
                    -e "s/X-Squid/${html_yellow}X-Squid${html_off}/g" \
                    -e "s/X-Server/${html_yellow}X-Server${html_off}/g" \
                    -e "s/X-Varnish/${html_yellow}X-Varnish${html_off}/g" \
                    -e "s/X-OWA-Version/${html_yellow}X-OWA-Version${html_off}/g" \
                    -e "s/MicrosoftSharePointTeamServices/${html_yellow}MicrosoftSharePointTeamServices${html_off}/g" \
                    -e "s/X-Application-Context/${html_yellow}X-Application-Context${html_off}/g" \
                    -e "s/X-Version/${html_yellow}X-Version${html_off}/g" \
                    -e "s/X-Powered-By/${html_yellow}X-Powered-By${html_off}/g" \
                    -e "s/X-UA-Compatible/${html_yellow}X-UA-Compatible${html_off}/g" \
                    -e "s/Link/${html_yellow}Link${html_off}/g" \
                    -e "s/X-Runtime/${html_yellow}X-Runtime${html_off}/g" \
                    -e "s/X-Rack-Cache/${html_yellow}X-Rack-Cache${html_off}/g" \
                    -e "s/X-Pingback/${html_yellow}X-Pingback${html_off}/g" \
                    -e "s/X-Permitted-Cross-Domain-Policies/${yellow}X-Permitted-Cross-Domain-Policies${html_off}/g" \
                    -e "s/X-AspNet-Version/${html_yellow}X-AspNet-Version${html_off}/g")" \
                    -e "s/x-note/${html_yellow}x-note${html_off}/g" \
                    -e "s/X-Global-Transaction-ID/${html_yellow}X-Global-Transaction-ID${html_off}/g" \
                    -e "s/x-global-transaction-id/${html_yellow}x-global-transaction-id${html_off}/g" \
                    -e "s/Alt-Svc/${html_yellow}Alt-Svc${html_off}/g" \
                    -e "s/system-wsgw-management-loopback/${yellow}system-wsgw-management-loopback${html_off}/g"
#FIXME: this is double code. The pattern to emphasize would fit better into
# one function.
# Also we need another function like run_other_header as otherwise "Link" "Alt-Svc" will never be found.
# And: I matches case sensitive only which might not detect all banners. (sed ignorecase is not possible w/ BSD sed)
          else
               html_out "$(html_reserved "$1")"
          fi
          html_out "\n"
     fi
}

run_server_banner() {
     local serverbanner
     local jsonID="banner_server"

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " Server banner                "
     grep -ai '^Server' $HEADERFILE >$TMPFILE
     if [[ $? -eq 0 ]]; then
          serverbanner=$(sed -e 's/^Server: //' -e 's/^server: //' $TMPFILE)
          if [[ "$serverbanner" == $'\n' ]] || [[ "$serverbanner" == $'\r' ]] || [[ "$serverbanner" == $'\n\r' ]] || [[ -z "$serverbanner" ]]; then
               outln "exists but empty string"
               fileout "$jsonID" "INFO" "Server banner is empty"
          else
               emphasize_stuff_in_headers "$serverbanner"
               fileout "$jsonID" "INFO" "$serverbanner"
               if [[ "$serverbanner" == *Microsoft-IIS/6.* ]] && [[ $OSSL_VER == 1.0.2* ]]; then
                    prln_warning "                              It's recommended to run another test w/ OpenSSL 1.0.1 !"
                    # see https://github.com/PeterMosmans/openssl/issues/19#issuecomment-100897892
                    fileout "${jsonID}" "WARN" "IIS6_openssl_mismatch: Recommended to rerun this test w/ OpenSSL 1.0.1. See https://github.com/PeterMosmans/openssl/issues/19#issuecomment-100897892"
               fi
          fi
          # mozilla.github.io/server-side-tls/ssl-config-generator/
          # https://support.microsoft.com/en-us/kb/245030
     else
          outln "(no \"Server\" line in header, interesting!)"
          fileout "$jsonID" "INFO" "No Server banner line in header, interesting!"
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

run_appl_banner() {
     local line
     local first=true
     local spaces="                              "
     local appl_banners=""
     local jsonID="banner_application"

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " Application banner           "
     grep -Eai '^X-Powered-By|^X-AspNet-Version|^X-Version|^Liferay-Portal|^X-OWA-Version^|^MicrosoftSharePointTeamServices' $HEADERFILE >$TMPFILE
     if [[ $? -ne 0 ]]; then
          outln "--"
          fileout "$jsonID" "INFO" "No application banner found"
     else
          while IFS='' read -r line; do
               line=$(strip_lf "$line")
               if ! $first; then
                    out "$spaces"
                    appl_banners="${appl_banners}, ${line}"
               else
                    appl_banners="${line}"
                    first=false
               fi
               emphasize_stuff_in_headers "$line"
          done < "$TMPFILE"
          fileout "$jsonID" "INFO" "$appl_banners"
     fi
     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

run_rp_banner() {
     local line
     local first=true
     local spaces="                              "
     local rp_banners=""
     local jsonID="banner_reverseproxy"
     local cwe="CWE-200"
     local cve=""

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi
     pr_bold " Reverse Proxy banner         "
     grep -Eai '^Via:|^X-Cache|^X-Squid|^X-Varnish:|^X-Server-Name:|^X-Server-Port:|^x-forwarded|^Forwarded' $HEADERFILE >$TMPFILE
     if [[ $? -ne 0 ]]; then
          outln "--"
          fileout "$jsonID" "INFO" "--" "$cve" "$cwe"
     else
          while read line; do
               line=$(strip_lf "$line")
               if $first; then
                    first=false
               else
                    out "$spaces"
               fi
               emphasize_stuff_in_headers "$line"
               rp_banners="${rp_banners}${line}"
          done < $TMPFILE
          fileout "$jsonID" "INFO" "$rp_banners" "$cve" "$cwe"
     fi
     outln

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


# arg1: multiline string w cookies
#
sub_f5_bigip_check() {
     local allcookies="$1"
     local ip port cookievalue cookiename
     local routed_domain offset
     local savedcookies=""
     local spaces="$2"
     local cwe="CWE-212"
     local cve=""

     # taken from https://github.com/drwetter/F5-BIGIP-Decoder, more details see there

     debugme echo -e "all cookies: >> $allcookies <<\n"
     while true; do IFS='=' read cookiename cookievalue
          [[ -z "$cookievalue" ]] && break
          cookievalue=${cookievalue/;/}
          debugme echo $cookiename : $cookievalue
          if grep -Eq '[0-9]{9,10}\.[0-9]{3,5}\.0000' <<< "$cookievalue"; then
               ip="$(f5_ip_oldstyle "$cookievalue")"
               port="$(f5_port_decode $cookievalue)"
               out "${spaces}F5 cookie (default IPv4 pool member): "; pr_italic "$cookiename "; prln_svrty_medium "${ip}:${port}"
               fileout "cookie_bigip_f5" "MEDIUM" "Information leakage: F5 cookie $cookiename $cookievalue is default IPv4 pool member ${ip}:${port}" "$cve" "$cwe"
          elif grep -Eq '^rd[0-9]{1,3}o0{20}f{4}[a-f0-9]{8}o[0-9]{1,5}' <<< "$cookievalue"; then
               routed_domain="$(f5_determine_routeddomain "$cookievalue")"
               offset=$(( 2 + ${#routed_domain} + 1 + 24))
               port="${cookievalue##*o}"
               ip="$(f5_hex2ip "${cookievalue:$offset:8}")"
               out "${spaces}F5 cookie (IPv4 pool in routed domain "; pr_svrty_medium "$routed_domain"; out "): "; pr_italic "$cookiename "; prln_svrty_medium "${ip}:${port}"
               fileout "cookie_bigip_f5" "MEDIUM" "Information leakage: F5 cookie $cookiename $cookievalue is IPv4 pool member in routed domain $routed_domain ${ip}:${port}" "$cve" "$cwe"
          elif grep -Eq '^vi[a-f0-9]{32}\.[0-9]{1,5}' <<< "$cookievalue"; then
               ip="$(f5_hex2ip6 ${cookievalue:2:32})"
               port="${cookievalue##*.}"
               port=$(f5_port_decode "$port")
               out "${spaces}F5 cookie (default IPv6 pool member): "; pr_italic "$cookiename "; prln_svrty_medium "${ip}:${port}"
               fileout "cookie_bigip_f5" "MEDIUM" "Information leakage: F5 cookie $cookiename $cookievalue is default IPv6 pool member ${ip}:${port}" "$cve" "$cwe"
          elif grep -Eq '^rd[0-9]{1,3}o[a-f0-9]{32}o[0-9]{1,5}' <<< "$cookievalue"; then
               routed_domain="$(f5_determine_routeddomain "$cookievalue")"
               offset=$(( 2 + ${#routed_domain} + 1 ))
               port="${cookievalue##*o}"
               ip="$(f5_hex2ip6 ${cookievalue:$offset:32})"
               out "${spaces}F5 cookie (IPv6 pool in routed domain "; pr_svrty_medium "$routed_domain"; out "): "; pr_italic "$cookiename "; prln_svrty_medium "${ip}:${port}"
               fileout "cookie_bigip_f5" "MEDIUM" "Information leakage: F5 cookie $cookiename $cookievalue is IPv6 pool member in routed domain $routed_domain ${ip}:${port}" "$cve" "$cwe"
          elif grep -Eq '^\!.*=$' <<< "$cookievalue"; then
               if [[ "${#cookievalue}" -eq 81 ]] ; then
                    savedcookies="${savedcookies}     ${cookiename}=${cookievalue:1:79}"
                    out "${spaces}Encrypted F5 cookie named "; pr_italic "${cookiename}"; outln " detected"
                    fileout "cookie_bigip_f5" "INFO" "encrypted F5 cookie named ${cookiename}"
               fi
          fi
     done <<< "$allcookies"
}


run_cookie_flags() {     # ARG1: Path
     local -i nr_cookies
     local -i nr_httponly nr_secure
     local negative_word
     local msg302="" msg302_=""
     local spaces="                              "

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi

     if [[ ! "$HTTP_STATUS_CODE" =~ 20 ]]; then
          if [[ "$HTTP_STATUS_CODE" =~ [301|302] ]]; then
               msg302=" -- maybe better try target URL of 30x"
               msg302_=" (30x detected, better try target URL of 30x)"
          else
               msg302=" -- HTTP status $HTTP_STATUS_CODE signals you maybe missed the web application"
               msg302_=" (maybe missed the application)"
          fi
     fi

     pr_bold " Cookie(s)                    "
     grep -ai '^Set-Cookie' $HEADERFILE >$TMPFILE
     if [[ $? -ne 0 ]]; then
          outln "(none issued at \"$1\")$msg302"
          fileout "cookie_count" "INFO" "0 at \"$1\"$msg302_"
     else
          nr_cookies=$(count_lines "$(cat $TMPFILE)")
          out "$nr_cookies issued: "
          fileout "cookie_count" "INFO" "$nr_cookies at \"$1\"$msg302_"
          if [[ $nr_cookies -gt 1 ]]; then
               negative_word="NONE"
          else
               negative_word="NOT"
          fi
          nr_secure=$(grep -iac secure $TMPFILE)
          case $nr_secure in
               0) pr_svrty_medium "$negative_word" ;;
               [123456789]) pr_svrty_good "$nr_secure/$nr_cookies";;
          esac
          out " secure, "
          if [[ $nr_cookies -eq $nr_secure ]]; then
               fileout "cookie_secure" "OK" "All ($nr_cookies) at \"$1\" marked as secure"
          else
               fileout "cookie_secure" "INFO" "$nr_secure/$nr_cookies at \"$1\" marked as secure"
          fi
          nr_httponly=$(grep -cai httponly $TMPFILE)
          case $nr_httponly in
               0) pr_svrty_medium "$negative_word" ;;
               [123456789]) pr_svrty_good "$nr_httponly/$nr_cookies";;
          esac
          out " HttpOnly"
          if [[ $nr_cookies -eq $nr_httponly ]]; then
               fileout "cookie_httponly" "OK" "All ($nr_cookies) at \"$1\" marked as HttpOnly$msg302_"
          else
               fileout "cookie_httponly" "INFO" "$nr_secure/$nr_cookies at \"$1\" marked as HttpOnly$msg302_"
          fi
          outln "$msg302"
          allcookies="$(awk '/[Ss][Ee][Tt]-[Cc][Oo][Oo][Kk][Ii][Ee]:/ { print $2 }' "$TMPFILE")"
          sub_f5_bigip_check "$allcookies" "$spaces"
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


run_security_headers() {
     local good_header="X-Frame-Options X-XSS-Protection X-Content-Type-Options Content-Security-Policy X-Content-Security-Policy X-WebKit-CSP Content-Security-Policy-Report-Only Expect-CT"
     local other_header="Access-Control-Allow-Origin Upgrade X-Served-By Referrer-Policy X-UA-Compatible"
     local header
     local first=true
     local spaces="                              "
     local have_header=false

     if [[ ! -s $HEADERFILE ]]; then
          run_http_header "$1" || return 1
     fi

     pr_bold " Security headers             "
     for header in $good_header; do
          [[ "$DEBUG" -ge 5 ]] &&  echo "testing \"$header\""
          match_httpheader_key "$header" "$header" "$spaces" "$first"
          if [[ $? -ge 1 ]]; then
               have_header=true
               if "$first"; then
                    first=false
               fi
               pr_svrty_good "$header"
               outln " $(out_row_aligned_max_width "$HEADERVALUE" "$(echo -n $header|sed 's/./ /g') $spaces" $TERM_WIDTH)"
               fileout "$header" "OK" "$HEADERVALUE"
          fi
     done

     for header in $other_header; do
          [[ "$DEBUG" -ge 5 ]] &&  echo "testing \"$header\""
          match_httpheader_key "$header" "$header" "$spaces" "$first"
          if [[ $? -ge 1 ]]; then
               have_header=true
               if "$first"; then
                    first=false
               fi
               pr_litecyan "$header"
               outln " $HEADERVALUE"     # shouldn't be that long
               fileout "$header" "INFO" "$HEADERVALUE"
          fi
     done
     #TODO: I am not testing for the correctness or anything stupid yet, e.g. "X-Frame-Options: allowall" or Access-Control-Allow-Origin: *

     if ! "$have_header"; then
          prln_svrty_medium "--"
          fileout "security_headers" "MEDIUM" "--"
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


# #1: string with 2 opensssl codes, output is same in NSS/ssllabs terminology
normalize_ciphercode() {
     if [[ "${1:2:2}" == "00" ]]; then
          tm_out "$(tolower "x${1:7:2}")"
     else
          tm_out "$(tolower "x${1:2:2}${1:7:2}${1:12:2}")"
     fi
     return 0
}

prettyprint_local() {
     local arg line
     local hexc hexcode dash ciph sslvers kx auth enc mac export
     local re='^[0-9A-Fa-f]+$'

     if [[ "$1" == 0x* ]] || [[ "$1" == 0X* ]]; then
          fatal "pls supply x<number> instead" $ERR_CMDLINE
     fi

     if [[ -z "$1" ]]; then
          pr_headline " Displaying all $OPENSSL_NR_CIPHERS local ciphers ";
     else
          pr_headline " Displaying all local ciphers ";
          # pattern provided; which one?
          [[ $1 =~ $re ]] && \
               pr_headline "matching number pattern \"$1\" " || \
               pr_headline "matching word pattern "\"$1\"" (ignore case) "
     fi
     outln "\n"
     neat_header

     if [[ -z "$1" ]]; then
          actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-V" | while read -r hexcode dash ciph sslvers kx auth enc mac export ; do       # -V doesn't work with openssl < 1.0
               hexc="$(normalize_ciphercode $hexcode)"
               outln "$(neat_list "$hexc" "$ciph" "$kx" "$enc")"
          done
     else
          #for arg in $(echo $@ | sed 's/,/ /g'); do
          for arg in ${*//,/ /}; do
               actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-V" | while read -r hexcode dash ciph sslvers kx auth enc mac export ; do # -V doesn't work with openssl < 1.0
                    hexc="$(normalize_ciphercode $hexcode)"
                    # for numbers we don't do word matching:
                    [[ $arg =~ $re ]] && \
                         line="$(neat_list "$hexc" "$ciph" "$kx" "$enc" | grep -ai "$arg")" || \
                         line="$(neat_list "$hexc" "$ciph" "$kx" "$enc" | grep -wai "$arg")"
                    [[ -n "$line" ]] && outln "$line"
               done
          done
     fi
     outln
     return 0
}


# Generic function for a rated output, no used yet.
# arg1: rating from 2 to -4 if available or not
# arg2: no/yes: decides whether positive or negative logic will be applied and "not" will be printed
# arg3: jsonID
#
rated_output() {
     local jsonID=$3
     local logic=""

     if [[ $2 == no ]] || [[ $2 == negative ]]; then
          logic="not "
     fi
     case $1 in
          2)   pr_svrty_best "${logic}offered (OK)"
               fileout "${jsonID}" "OK" "${logic}offered"
               ;;
          1)   pr_svrty_good "${logic}offered (OK)"
               fileout "${jsonID}" "OK" "${logic}offered"
               ;;
          0)   out "${logic}offered"
               fileout "${jsonID}" "INFO" "${logic}offered"
               ;;
          -1)  pr_svrty_low "${logic}offered"
               fileout "${jsonID}" "LOW" "${logic}offered"
               ;;
          -2)  pr_svrty_medium "${logic}offered"
               fileout "${jsonID}" "MEDIUM" "${logic}offered"
               ;;
          -3)  pr_svrty_high "${logic}offered (NOT ok)"
               fileout "${jsonID}" "HIGH" "${logic}offered"
               ;;
          -4)  pr_svrty_critical "${logic}offered (NOT ok)"
               fileout "${jsonID}" "CRITICAL" "${logic}offered"
               ;;
          *)   pr_warning "FIXME: error around $LINENO, (please report this)"
               fileout "${jsonID}" "WARN" "return condition $2 when $1 unclear"
               return 1
               ;;
     esac
     return 0
}


openssl2rfc() {
     local rfcname=""
     local -i i

     for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
          [[ "$1" == ${TLS_CIPHER_OSSL_NAME[i]} ]] && rfcname="${TLS_CIPHER_RFC_NAME[i]}" && break
     done
     [[ "$rfcname" == "-" ]] && rfcname=""
     [[ -n "$rfcname" ]] && tm_out "$rfcname"
     return 0
}

rfc2openssl() {
     local ossl_name
     local -i i

     for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
          [[ "$1" == ${TLS_CIPHER_RFC_NAME[i]} ]] && ossl_name="${TLS_CIPHER_OSSL_NAME[i]}" && break
     done
     [[ "$ossl_name" == "-" ]] && ossl_name=""
     [[ -n "$ossl_name" ]] && tm_out "$ossl_name"
     return 0
}

openssl2hexcode() {
     local hexc=""
     local -i i

     if [[ $TLS_NR_CIPHERS -eq 0 ]]; then
          if "$HAS_CIPHERSUITES"; then
               hexc="$($OPENSSL ciphers -V -ciphersuites "$TLS13_OSSL_CIPHERS" 'ALL:COMPLEMENTOFALL:@STRENGTH' | awk '/ '"$1"' / { print $1 }')"
          else
               hexc="$($OPENSSL ciphers -V 'ALL:COMPLEMENTOFALL:@STRENGTH' | awk '/ '"$1"' / { print $1 }')"
          fi
     else
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               [[ "$1" == ${TLS_CIPHER_OSSL_NAME[i]} ]] && hexc="${TLS_CIPHER_HEXCODE[i]}" && break
          done
     fi
     [[ -z "$hexc" ]] && return 1
     tm_out "$hexc"
     return 0
}

rfc2hexcode() {
     local hexc=""
     local -i i

     for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
          [[ "$1" == "${TLS_CIPHER_RFC_NAME[i]}" ]] && hexc="${TLS_CIPHER_HEXCODE[i]}" && break
     done
     [[ -z "$hexc" ]] && return 1
     tm_out "$hexc"
     return 0
}

show_rfc_style(){
     local rfcname="" hexcode
     local -i i

     hexcode="$(toupper "$1")"
     case ${#hexcode} in
          3) hexcode="0x00,0x${hexcode:1:2}" ;;
          5) hexcode="0x${hexcode:1:2},0x${hexcode:3:2}" ;;
          7) hexcode="0x${hexcode:1:2},0x${hexcode:3:2},0x${hexcode:5:2}" ;;
          *) return 1 ;;
     esac
     for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
          [[ "$hexcode" == ${TLS_CIPHER_HEXCODE[i]} ]] && rfcname="${TLS_CIPHER_RFC_NAME[i]}" && break
     done
     [[ "$rfcname" == "-" ]] && rfcname=""
     [[ -n "$rfcname" ]] && tm_out "$rfcname"
     return 0
}

neat_header(){
     if [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]]; then
          out "$(printf -- "Hexcode  Cipher Suite Name (IANA/RFC)                      KeyExch.   Encryption  Bits")"
          [[ "$DISPLAY_CIPHERNAMES" != rfc-only ]] && out "$(printf -- "     Cipher Suite Name (OpenSSL)")"
          outln
          out "$(printf -- "%s------------------------------------------------------------------------------------------")"
          [[ "$DISPLAY_CIPHERNAMES" != rfc-only ]] && out "$(printf -- "---------------------------------------")"
          outln
     else
          out "$(printf -- "Hexcode  Cipher Suite Name (OpenSSL)       KeyExch.   Encryption  Bits")"
          [[ "$DISPLAY_CIPHERNAMES" != openssl-only ]] && out "$(printf -- "     Cipher Suite Name (IANA/RFC)")"
          outln
          out "$(printf -- "%s--------------------------------------------------------------------------")"
          [[ "$DISPLAY_CIPHERNAMES" != openssl-only ]] && out "$(printf -- "---------------------------------------------------")"
          outln
     fi
}


# arg1: hexcode
# arg2: cipher in openssl notation
# arg3: keyexchange
# arg4: encryption (maybe included "export")
# arg5: "true" if the cipher's "quality" should be highlighted
#       "false" if the line should be printed in light grey
#       empty if line should be returned as a string
neat_list(){
     local hexcode="$1"
     local ossl_cipher="$2" tls_cipher=""
     local kx enc strength line what_dh bits
     local -i i len

     kx="${3//Kx=/}"
     enc="${4//Enc=/}"
     # In two cases LibreSSL uses very long names for encryption algorithms
     # and doesn't include the number of bits.
     [[ "$enc" == ChaCha20-Poly1305 ]] && enc="CHACHA20(256)"
     [[ "$enc" == GOST-28178-89-CNT ]] && enc="GOST(256)"

     strength="${enc//\)/}"             # retrieve (). first remove traling ")"
     strength="${strength#*\(}"         # exfiltrate (VAL
     enc="${enc%%\(*}"

     enc="${enc//POLY1305/}"            # remove POLY1305
     enc="${enc//\//}"                  # remove "/"

     [[ "$export" =~ export ]] && strength="$strength,exp"

     [[ "$DISPLAY_CIPHERNAMES" != openssl-only ]] && tls_cipher="$(show_rfc_style "$hexcode")"

     if [[ "$5" != true ]]; then
          if [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]]; then
               line="$(printf -- " %-7s %-49s %-10s %-12s%-8s" "$hexcode" "$tls_cipher" "$kx" "$enc" "$strength")"
               [[ "$DISPLAY_CIPHERNAMES" != rfc-only ]] && line+="$(printf -- " %-33s${SHOW_EACH_C:+  %-0s}" "$ossl_cipher")"
          else
               line="$(printf -- " %-7s %-33s %-10s %-12s%-8s" "$hexcode" "$ossl_cipher" "$kx" "$enc" "$strength")"
               [[ "$DISPLAY_CIPHERNAMES" != openssl-only ]] && line+="$(printf -- " %-49s${SHOW_EACH_C:+  %-0s}" "$tls_cipher")"
          fi
          if [[ -z "$5" ]]; then
               tm_out "$line"
          else
               pr_deemphasize "$line"
          fi
          return 0
     fi
     if [[ "$kx" =~ " " ]]; then
          what_dh="${kx%% *}"
          bits="${kx##* }"
     else
          what_dh="$kx"
          bits=""
     fi
     if [[ "$COLOR" -le 2 ]]; then
          if [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]]; then
               out "$(printf -- " %-7s %-49s " "$hexcode" "$tls_cipher")"
          else
               out "$(printf -- " %-7s %-33s " "$hexcode" "$ossl_cipher")"
          fi
     else
          out "$(printf -- " %-7s " "$hexcode")"
          if [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]]; then
               print_fixed_width "$tls_cipher" 49 pr_cipher_quality
          else
               print_fixed_width "$ossl_cipher" 33 pr_cipher_quality
          fi
     fi
     out "$what_dh"
     if [[ -n "$bits" ]]; then
          if [[ $what_dh == DH ]] || [[ $what_dh == EDH ]]; then
               pr_dh_quality "$bits" " $bits"
          elif [[ $what_dh == ECDH ]]; then
               pr_ecdh_quality "$bits" " $bits"
          fi
     fi
     len=${#kx}
     for (( i=len; i<10; i++ )); do
          out " "
     done
     out "$(printf -- " %-12s%-8s " "$enc" "$strength")"
     if [[ "$COLOR" -le 2 ]]; then
          if [[ "$DISPLAY_CIPHERNAMES" == rfc ]]; then
               out "$(printf -- "%-33s${SHOW_EACH_C:+  %-0s}" "$ossl_cipher")"
          elif [[ "$DISPLAY_CIPHERNAMES" == openssl ]]; then
               out "$(printf -- "%-49s${SHOW_EACH_C:+  %-0s}" "$tls_cipher")"
          fi
     else
          if [[ "$DISPLAY_CIPHERNAMES" == rfc ]]; then
               print_fixed_width "$ossl_cipher" 32 pr_cipher_quality
          elif [[ "$DISPLAY_CIPHERNAMES" == openssl ]]; then
               print_fixed_width "$tls_cipher" 48 pr_cipher_quality
          fi
          out "$(printf -- "${SHOW_EACH_C:+  %-0s}")"
     fi
}

run_cipher_match(){
     local hexc n auth export ciphers_to_test tls13_ciphers_to_test supported_sslv2_ciphers s
     local -a hexcode normalized_hexcode ciph sslvers kx enc export2 sigalg
     local -a ciphers_found ciphers_found2 ciph2 rfc_ciph rfc_ciph2 ossl_supported
     local -a -i index
     local -i nr_ciphers=0 nr_ossl_ciphers=0 nr_nonossl_ciphers=0
     local -i num_bundles mod_check bundle_size bundle end_of_bundle
     local dhlen has_dh_bits="$HAS_DH_BITS"
     local cipher proto protos_to_try
     local available
     local -i sclient_success
     local re='^[0-9A-Fa-f]+$'
     local using_sockets=true

     "$SSL_NATIVE" && using_sockets=false
     "$FAST" && using_sockets=false
     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

     pr_headline " Testing ciphers with "
     if [[ $1 =~ $re ]]; then
          pr_headline "matching number pattern \"$1\" "
          tjolines="$tjolines matching number pattern \"$1\"\n\n"
     else
          pr_headline "word pattern "\"$1\"" (ignore case) "
          tjolines="$tjolines word pattern \"$1\" (ignore case)\n\n"
     fi
     outln
     if ! "$using_sockets"; then
          [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && pr_warning " Cipher mapping not available, doing a fallback to openssl"
          if ! "$HAS_DH_BITS"; then
               [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && out "."
               prln_warning "    (Your $OPENSSL cannot show DH/ECDH bits)"
          fi
     fi
     outln
     neat_header
     #for arg in $(echo $@ | sed 's/,/ /g'); do
     for arg in ${*//, /}; do
          if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
               for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
                    hexc="${TLS_CIPHER_HEXCODE[i]}"
                    if [[ ${#hexc} -eq 9 ]]; then
                         hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2}"
                         if [[ "${hexc:2:2}" == "00" ]]; then
                              normalized_hexcode[nr_ciphers]="x${hexc:7:2}"
                         else
                              normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}"
                         fi
                    else
                         hexc="$(tolower "$hexc")"
                         hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2},${hexc:12:2}"
                         normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}${hexc:12:2}"
                    fi
                    if [[ $arg =~ $re ]]; then
                         neat_list "${normalized_hexcode[nr_ciphers]}" "${TLS_CIPHER_OSSL_NAME[i]}" "${TLS_CIPHER_KX[i]}" "${TLS_CIPHER_ENC[i]}" | grep -qai "$arg"
                    else
                         neat_list "${normalized_hexcode[nr_ciphers]}" "${TLS_CIPHER_OSSL_NAME[i]}" "${TLS_CIPHER_KX[i]}" "${TLS_CIPHER_ENC[i]}" | grep -qwai "$arg"
                    fi
                    if [[ $? -eq 0 ]] && ( "$using_sockets" || "${TLS_CIPHER_OSSL_SUPPORTED[i]}" ); then    # string matches, so we can ssl to it:
                         normalized_hexcode[nr_ciphers]="$(tolower "${normalized_hexcode[nr_ciphers]}")"
                         ciph[nr_ciphers]="${TLS_CIPHER_OSSL_NAME[i]}"
                         rfc_ciph[nr_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                         kx[nr_ciphers]="${TLS_CIPHER_KX[i]}"
                         enc[nr_ciphers]="${TLS_CIPHER_ENC[i]}"
                         sslvers[nr_ciphers]="${TLS_CIPHER_SSLVERS[i]}"
                         export2[nr_ciphers]="${TLS_CIPHER_EXPORT[i]}"
                         ciphers_found[nr_ciphers]=false
                         sigalg[nr_ciphers]=""
                         ossl_supported[nr_ciphers]="${TLS_CIPHER_OSSL_SUPPORTED[i]}"
                         if "$using_sockets" && ! "$has_dh_bits" && \
                            ( [[ ${kx[nr_ciphers]} == "Kx=ECDH" ]] || [[ ${kx[nr_ciphers]} == "Kx=DH" ]] || [[ ${kx[nr_ciphers]} == "Kx=EDH" ]] ); then
                              ossl_supported[nr_ciphers]=false
                         fi
                         nr_ciphers+=1
                    fi
               done
          else
               while read hexc n ciph[nr_ciphers] sslvers[nr_ciphers] kx[nr_ciphers] auth enc[nr_ciphers] mac export2[nr_ciphers]; do
                    hexc="$(normalize_ciphercode $hexc)"
                    # is argument a number?
                    if [[ $arg =~ $re ]]; then
                         neat_list "$hexc" "${ciph[nr_ciphers]}" "${kx[nr_ciphers]}" "${enc[nr_ciphers]}" | grep -qai "$arg"
                    else
                         neat_list "$hexc" "${ciph[nr_ciphers]}" "${kx[nr_ciphers]}" "${enc[nr_ciphers]}" | grep -qwai "$arg"
                    fi
                    if [[ $? -eq 0 ]]; then    # string matches, so we can ssl to it:
                         ciphers_found[nr_ciphers]=false
                         normalized_hexcode[nr_ciphers]="$hexc"
                         sigalg[nr_ciphers]=""
                         ossl_supported[nr_ciphers]=true
                         nr_ciphers+=1
                    fi
               done < <(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-V")
          fi

          # Test the SSLv2 ciphers, if any.
          if "$using_sockets"; then
               ciphers_to_test=""
               for (( i=0; i < nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == "SSLv2" ]]; then
                         ciphers_to_test+=", ${hexcode[i]}"
                    fi
               done
               if [[ -n "$ciphers_to_test" ]]; then
                    sslv2_sockets "${ciphers_to_test:2}" "true"
                    if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
                         supported_sslv2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
                         "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$HOSTCERT")"
                         for (( i=0 ; i<nr_ciphers; i++ )); do
                              if [[ "${sslvers[i]}" == "SSLv2" ]] && [[ "$supported_sslv2_ciphers" =~ ${normalized_hexcode[i]} ]]; then
                                   ciphers_found[i]=true
                                   "$SHOW_SIGALGO" && sigalg[i]="$s"
                              fi
                         done
                    fi
               fi
          else
               ciphers_to_test=""
               for (( i=0; i < nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == "SSLv2" ]]; then
                         ciphers_to_test+=":${ciph[i]}"
                    fi
               done
               if [[ -n "$ciphers_to_test" ]]; then
                    $OPENSSL s_client -cipher "${ciphers_to_test:1}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY -ssl2 >$TMPFILE 2>$ERRFILE </dev/null
                    sclient_connect_successful $? "$TMPFILE"
                    if [[ $? -eq 0 ]]; then
                         supported_sslv2_ciphers="$(grep -A 4 "Ciphers common between both SSL endpoints:" $TMPFILE)"
                         "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$TMPFILE")"
                         for (( i=0 ; i<nr_ciphers; i++ )); do
                              if [[ "${sslvers[i]}" == "SSLv2" ]] && [[ "$supported_sslv2_ciphers" =~ ${ciph[i]} ]]; then
                                   ciphers_found[i]=true
                                   "$SHOW_SIGALGO" && sigalg[i]="$s"
                              fi
                         done
                    fi
               fi
          fi

          for (( i=0; i < nr_ciphers; i++ )); do
               if "${ossl_supported[i]}" && [[ "${sslvers[i]}" != "SSLv2" ]]; then
                    ciphers_found2[nr_ossl_ciphers]=false
                    ciph2[nr_ossl_ciphers]="${ciph[i]}"
                    index[nr_ossl_ciphers]=$i
                    nr_ossl_ciphers+=1
               fi
          done
          if [[ $nr_ossl_ciphers -eq 0 ]]; then
               num_bundles=0
          else
               # Some servers can't handle a handshake with >= 128 ciphers. So,
               # test cipher suites in bundles of 128 or less.
               num_bundles=$nr_ossl_ciphers/128
               mod_check=$nr_ossl_ciphers%128
               [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

               bundle_size=$nr_ossl_ciphers/$num_bundles
               mod_check=$nr_ossl_ciphers%$num_bundles
               [[ $mod_check -ne 0 ]] && bundle_size+=1
          fi

          if "$HAS_TLS13"; then
               protos_to_try="-no_ssl2 -tls1_2 -tls1_1 -tls1"
          else
               protos_to_try="-no_ssl2 -tls1_1 -tls1"
          fi
          "$HAS_SSL3" && protos_to_try+=" -ssl3"

          for proto in $protos_to_try; do
               if [[ "$proto" == "-tls1_1" ]]; then
                    num_bundles=1
                    bundle_size=$nr_ossl_ciphers
               fi
               for (( bundle=0; bundle < num_bundles; bundle++ )); do
                    end_of_bundle=$bundle*$bundle_size+$bundle_size
                    [[ $end_of_bundle -gt $nr_ossl_ciphers ]] && end_of_bundle=$nr_ossl_ciphers
                    while true; do
                         ciphers_to_test=""
                         tls13_ciphers_to_test=""
                         for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                              if ! "${ciphers_found2[i]}"; then
                                   if [[ "${ciph2[i]}" == TLS13* ]] || [[ "${ciph2[i]}" == TLS_* ]]; then
                                        tls13_ciphers_to_test+=":${ciph2[i]}"
                                   else
                                        ciphers_to_test+=":${ciph2[i]}"
                                   fi
                              fi
                         done
                         [[ -z "$ciphers_to_test" ]] && [[ -z "$tls13_ciphers_to_test" ]] && break
                         $OPENSSL s_client $(s_client_options "$proto -cipher "\'${ciphers_to_test:1}\'" -ciphersuites "\'${tls13_ciphers_to_test:1}\'" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
                         sclient_connect_successful $? "$TMPFILE" || break
                         cipher=$(get_cipher $TMPFILE)
                         [[ -z "$cipher" ]] && break
                         for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                              [[ "$cipher" == "${ciph2[i]}" ]] && ciphers_found2[i]=true && break
                         done
                         [[ $i -eq $end_of_bundle ]] && break
                         i=${index[i]}
                         ciphers_found[i]=true
                         if [[ "$cipher" == TLS13* ]] || [[ "$cipher" == TLS_* ]]; then
                              kx[i]="$(read_dhtype_from_file $TMPFILE)"
                         fi
                         if [[ ${kx[i]} == "Kx=ECDH" ]] || [[ ${kx[i]} == "Kx=DH" ]] || [[ ${kx[i]} == "Kx=EDH" ]]; then
                              dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                              kx[i]="${kx[i]} $dhlen"
                         fi
                         "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                              sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
                    done
               done
          done

          if "$using_sockets"; then
               for (( i=0; i < nr_ciphers; i++ )); do
                    if ! "${ciphers_found[i]}" && [[ "${sslvers[i]}" != "SSLv2" ]]; then
                         ciphers_found2[nr_nonossl_ciphers]=false
                         hexcode2[nr_nonossl_ciphers]="${hexcode[i]}"
                         rfc_ciph2[nr_nonossl_ciphers]="${rfc_ciph[i]}"
                         index[nr_nonossl_ciphers]=$i
                         nr_nonossl_ciphers+=1
                    fi
               done
          fi

          if [[ $nr_nonossl_ciphers -eq 0 ]]; then
               num_bundles=0
          else
               # Some servers can't handle a handshake with >= 128 ciphers. So,
               # test cipher suites in bundles of 128 or less.
               num_bundles=$nr_nonossl_ciphers/128
               mod_check=$nr_nonossl_ciphers%128
               [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

               bundle_size=$nr_nonossl_ciphers/$num_bundles
               mod_check=$nr_nonossl_ciphers%$num_bundles
               [[ $mod_check -ne 0 ]] && bundle_size+=1
          fi

          for proto in 04 03 02 01 00; do
               for (( bundle=0; bundle < num_bundles; bundle++ )); do
                    end_of_bundle=$bundle*$bundle_size+$bundle_size
                    [[ $end_of_bundle -gt $nr_nonossl_ciphers ]] && end_of_bundle=$nr_nonossl_ciphers
                    while true; do
                         ciphers_to_test=""
                         for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                              ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode2[i]}"
                         done
                         [[ -z "$ciphers_to_test" ]] && break
                         [[ "$proto" == "04" ]] && [[ ! "$ciphers_to_test" =~ ,\ 13,[0-9a-f][0-9a-f] ]] && break
                         ciphers_to_test="$(strip_inconsistent_ciphers "$proto" "$ciphers_to_test")"
                         [[ -z "$ciphers_to_test" ]] && break
                         if "$SHOW_SIGALGO"; then
                              tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "all"
                         else
                              tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
                         fi
                         sclient_success=$?
                         [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
                         cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                         for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                              [[ "$cipher" == "${rfc_ciph2[i]}" ]] && ciphers_found2[i]=true && break
                         done
                         [[ $i -eq $end_of_bundle ]] && break
                         i=${index[i]}
                         ciphers_found[i]=true
                         [[ "${kx[i]}" == "Kx=any" ]] && kx[i]="$(read_dhtype_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")"
                         if [[ ${kx[i]} == "Kx=ECDH" ]] || [[ ${kx[i]} == "Kx=DH" ]] || [[ ${kx[i]} == "Kx=EDH" ]]; then
                              dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                              kx[i]="${kx[i]} $dhlen"
                         fi
                         "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && \
                               sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
                    done
               done
          done

          for (( i=0; i < nr_ciphers; i++ )); do
               "${ciphers_found[i]}" || "$SHOW_EACH_C" || continue
               export="${export2[i]}"
               neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
               available=""
               if "$SHOW_EACH_C"; then
                    if "${ciphers_found[i]}"; then
                         available="available"
                         pr_cyan "available"
                    else
                         available="not a/v"
                         pr_deemphasize "not a/v"
                    fi
               fi
               outln "${sigalg[i]}"
               fileout "cipher_${normalized_hexcode[i]}" "INFO" "$(neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}") $available"
          done
          "$using_sockets" && HAS_DH_BITS="$has_dh_bits"
          tmpfile_handle ${FUNCNAME[0]}.txt
     done
     outln

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0       # this is a single test for a cipher
}



# test for all ciphers locally configured (w/o distinguishing whether they are good or bad)
run_allciphers() {
     local -i nr_ciphers_tested=0 nr_ciphers=0 nr_ossl_ciphers=0 nr_nonossl_ciphers=0 sclient_success=0
     local n auth mac export hexc sslv2_ciphers="" s
     local -a normalized_hexcode hexcode ciph sslvers kx enc export2 sigalg ossl_supported
     local -i i end_of_bundle bundle bundle_size num_bundles mod_check
     local -a ciphers_found ciphers_found2 hexcode2 ciph2 rfc_ciph2
     local -i -a index
     local proto protos_to_try
     local dhlen available ciphers_to_test tls13_ciphers_to_test supported_sslv2_ciphers
     local has_dh_bits="$HAS_DH_BITS"
     local using_sockets=true

     "$SSL_NATIVE" && using_sockets=false
     "$FAST" && using_sockets=false
     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

     # get a list of all the cipher suites to test
     if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               hexc="$(tolower "${TLS_CIPHER_HEXCODE[i]}")"
               ciph[i]="${TLS_CIPHER_OSSL_NAME[i]}"
               sslvers[i]="${TLS_CIPHER_SSLVERS[i]}"
               kx[i]="${TLS_CIPHER_KX[i]}"
               enc[i]="${TLS_CIPHER_ENC[i]}"
               export2[i]="${TLS_CIPHER_EXPORT[i]}"
               ciphers_found[i]=false
               sigalg[i]=""
               ossl_supported[i]=${TLS_CIPHER_OSSL_SUPPORTED[i]}
               if "$using_sockets" && ! "$HAS_DH_BITS" && ( [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]] ); then
                    ossl_supported[i]=false
               fi
               if [[ ${#hexc} -eq 9 ]]; then
                    hexcode[i]="${hexc:2:2},${hexc:7:2}"
                    if [[ "${hexc:2:2}" == "00" ]]; then
                         normalized_hexcode[i]="x${hexc:7:2}"
                    else
                         normalized_hexcode[i]="x${hexc:2:2}${hexc:7:2}"
                    fi
               else
                    hexcode[i]="${hexc:2:2},${hexc:7:2},${hexc:12:2}"
                    normalized_hexcode[i]="x${hexc:2:2}${hexc:7:2}${hexc:12:2}"
                    sslv2_ciphers="$sslv2_ciphers, ${hexcode[i]}"
               fi
               if "$using_sockets" || "${TLS_CIPHER_OSSL_SUPPORTED[i]}"; then
                    nr_ciphers_tested+=1
               fi
          done
          nr_ciphers=$TLS_NR_CIPHERS
     else
          while read -r hexc n ciph[nr_ciphers] sslvers[nr_ciphers] kx[nr_ciphers] auth enc[nr_ciphers] mac export2[nr_ciphers]; do
               ciphers_found[nr_ciphers]=false
               if [[ ${#hexc} -eq 9 ]]; then
                    if [[ "${hexc:2:2}" == "00" ]]; then
                         normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:7:2}")"
                    else
                         normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:2:2}${hexc:7:2}")"
                    fi
               else
                    normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:2:2}${hexc:7:2}${hexc:12:2}")"
               fi
               sigalg[nr_ciphers]=""
               ossl_supported[nr_ciphers]=true
               nr_ciphers=$nr_ciphers+1
          done < <(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-V")
          nr_ciphers_tested=$nr_ciphers
     fi

     if "$using_sockets"; then
          sslv2_sockets "${sslv2_ciphers:2}" "true"
          if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
               supported_sslv2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
               "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$HOSTCERT")"
               for (( i=0 ; i<nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == SSLv2 ]] && [[ "$supported_sslv2_ciphers" =~ ${normalized_hexcode[i]} ]]; then
                         ciphers_found[i]=true
                         "$SHOW_SIGALGO" && sigalg[i]="$s"
                    fi
               done
          fi
     elif "$HAS_SSL2"; then
          $OPENSSL s_client $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY -ssl2 >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? "$TMPFILE"
          if [[ $? -eq 0 ]]; then
               supported_sslv2_ciphers="$(grep -A 4 "Ciphers common between both SSL endpoints:" $TMPFILE)"
               "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$TMPFILE")"
               for (( i=0 ; i<nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == "SSLv2" ]] && [[ "$supported_sslv2_ciphers" =~ ${ciph[i]} ]]; then
                         ciphers_found[i]=true
                         "$SHOW_SIGALGO" && sigalg[i]="$s"
                    fi
               done
          fi
     fi

     outln
     if "$using_sockets"; then
          pr_headlineln " Testing $nr_ciphers_tested ciphers via OpenSSL plus sockets against the server, ordered by encryption strength "
     else
          pr_headlineln " Testing all $nr_ciphers_tested locally available ciphers against the server, ordered by encryption strength "
          [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && pr_warning " Cipher mapping not available, doing a fallback to openssl"
          outln
          if ! "$HAS_DH_BITS"; then
               [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && out "."
               prln_warning " Your $OPENSSL cannot show DH/ECDH bits"
          fi
     fi
     outln
     neat_header

     for (( i=0; i < nr_ciphers; i++ )); do
          if "${ossl_supported[i]}"; then
               [[ "${sslvers[i]}" == SSLv2 ]] && continue
               ciphers_found2[nr_ossl_ciphers]=false
               ciph2[nr_ossl_ciphers]="${ciph[i]}"
               index[nr_ossl_ciphers]=$i
               nr_ossl_ciphers+=1
          fi
     done

     if [[ $nr_ossl_ciphers -eq 0 ]]; then
          num_bundles=0
     else
          # Some servers can't handle a handshake with >= 128 ciphers. So,
          # test cipher suites in bundles of 128 or less.
          num_bundles=$nr_ossl_ciphers/128
          mod_check=$nr_ossl_ciphers%128
          [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

          bundle_size=$nr_ossl_ciphers/$num_bundles
          mod_check=$nr_ossl_ciphers%$num_bundles
          [[ $mod_check -ne 0 ]] && bundle_size+=1
     fi

     if "$HAS_TLS13"; then
          protos_to_try="-no_ssl2 -tls1_2 -tls1_1 -tls1"
     else
          protos_to_try="-no_ssl2 -tls1_1 -tls1"
     fi
     "$HAS_SSL3" && protos_to_try+=" -ssl3"

     for proto in $protos_to_try; do
          if [[ "$proto" == "-tls1_1" ]]; then
               num_bundles=1
               bundle_size=$nr_ossl_ciphers
          fi

          [[ "$proto" != "-no_ssl2" ]] && [[ $(has_server_protocol "${proto:1}") -eq 1 ]] && continue
          for (( bundle=0; bundle < num_bundles; bundle++ )); do
               end_of_bundle=$bundle*$bundle_size+$bundle_size
               [[ $end_of_bundle -gt $nr_ossl_ciphers ]] && end_of_bundle=$nr_ossl_ciphers
               while true; do
                    ciphers_to_test=""
                    tls13_ciphers_to_test=""
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         if ! "${ciphers_found2[i]}"; then
                              if [[ "${ciph2[i]}" == TLS13* ]] || [[ "${ciph2[i]}" == TLS_* ]]; then
                                   tls13_ciphers_to_test+=":${ciph2[i]}"
                              else
                                   ciphers_to_test+=":${ciph2[i]}"
                              fi
                         fi
                    done
                    [[ -z "$ciphers_to_test" ]] && [[ -z "$tls13_ciphers_to_test" ]] && break
                    $OPENSSL s_client $(s_client_options "$proto -cipher "\'${ciphers_to_test:1}\'" -ciphersuites "\'${tls13_ciphers_to_test:1}\'" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
                    sclient_connect_successful $? "$TMPFILE" || break
                    cipher=$(get_cipher $TMPFILE)
                    [[ -z "$cipher" ]] && break
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         [[ "$cipher" == "${ciph2[i]}" ]] && ciphers_found2[i]=true && break
                    done
                    [[ $i -eq $end_of_bundle ]] && break
                    i=${index[i]}
                    ciphers_found[i]=true
                    if [[ "$cipher" == TLS13* ]] || [[ "$cipher" == TLS_* ]]; then
                         kx[i]="$(read_dhtype_from_file $TMPFILE)"
                    fi
                    if [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]]; then
                         dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                         kx[i]="${kx[i]} $dhlen"
                    fi
                    "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                         sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
               done
          done
     done

     if "$using_sockets"; then
          for (( i=0; i < nr_ciphers; i++ )); do
               if ! "${ciphers_found[i]}"; then
                    [[ "${sslvers[i]}" == "SSLv2" ]] && continue
                    ciphers_found2[nr_nonossl_ciphers]=false
                    hexcode2[nr_nonossl_ciphers]="${hexcode[i]}"
                    rfc_ciph2[nr_nonossl_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                    index[nr_nonossl_ciphers]=$i
                    nr_nonossl_ciphers+=1
               fi
          done
     fi

     if [[ $nr_nonossl_ciphers -eq 0 ]]; then
          num_bundles=0
     else
          # Some servers can't handle a handshake with >= 128 ciphers. So,
          # test cipher suites in bundles of 128 or less.
          num_bundles=$nr_nonossl_ciphers/128
          mod_check=$nr_nonossl_ciphers%128
          [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

          bundle_size=$nr_nonossl_ciphers/$num_bundles
          mod_check=$nr_nonossl_ciphers%$num_bundles
          [[ $mod_check -ne 0 ]] && bundle_size+=1
     fi

     for proto in 04 03 02 01 00; do
          for (( bundle=0; bundle < num_bundles; bundle++ )); do
               end_of_bundle=$bundle*$bundle_size+$bundle_size
               [[ $end_of_bundle -gt $nr_nonossl_ciphers ]] && end_of_bundle=$nr_nonossl_ciphers
               while true; do
                    ciphers_to_test=""
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode2[i]}"
                    done
                    [[ -z "$ciphers_to_test" ]] && break
                    [[ "$proto" == "04" ]] && [[ ! "$ciphers_to_test" =~ ,\ 13,[0-9a-f][0-9a-f] ]] && break
                    ciphers_to_test="$(strip_inconsistent_ciphers "$proto" "$ciphers_to_test")"
                    [[ -z "$ciphers_to_test" ]] && break
                    if "$SHOW_SIGALGO"; then
                         tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "all"
                    else
                         tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
                    fi
                    sclient_success=$?
                    [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
                    cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         [[ "$cipher" == "${rfc_ciph2[i]}" ]] && ciphers_found2[i]=true && break
                    done
                    [[ $i -eq $end_of_bundle ]] && break
                    i=${index[i]}
                    ciphers_found[i]=true
                    [[ "${kx[i]}" == "Kx=any" ]] && kx[i]="$(read_dhtype_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")"
                    if [[ ${kx[i]} == "Kx=ECDH" ]] || [[ ${kx[i]} == "Kx=DH" ]] || [[ ${kx[i]} == "Kx=EDH" ]]; then
                         dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                         kx[i]="${kx[i]} $dhlen"
                    fi
                    "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
               done
          done
     done

     for (( i=0 ; i<nr_ciphers; i++ )); do
          if "${ciphers_found[i]}" || ( "$SHOW_EACH_C" && ( "$using_sockets" || "${ossl_supported[i]}" ) ); then
               export=${export2[i]}
               neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
               available=""
               if "$SHOW_EACH_C"; then
                    if ${ciphers_found[i]}; then
                         available="available"
                         pr_cyan "$available"
                    else
                         available="not a/v"
                         pr_deemphasize "$available"
                    fi
               fi
               outln "${sigalg[i]}"
               fileout "cipher_${normalized_hexcode[i]}" "INFO" "$(neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}") $available"
          fi
     done
     "$using_sockets" && HAS_DH_BITS="$has_dh_bits"

     outln
     [[ $sclient_success -ge 6 ]] && return 1
     return 0
}

# test for all ciphers per protocol locally configured (w/o distinguishing whether they are good or bad)
# for the specified protocol, test for all ciphers locally configured (w/o distinguishing whether they
# are good or bad) and list them in order to encryption strength.
ciphers_by_strength() {
     local proto="$1" proto_hex="$2" proto_text="$3"
     local using_sockets="$4"
     local ossl_ciphers_proto
     local -i nr_ciphers nr_ossl_ciphers nr_nonossl_ciphers success
     local n sslvers auth mac export hexc sslv2_ciphers="" cipher
     local -a hexcode normalized_hexcode ciph rfc_ciph kx enc export2
     local -a hexcode2 ciph2 rfc_ciph2
     local -i i bundle end_of_bundle bundle_size num_bundles mod_check
     local -a ciphers_found ciphers_found2 sigalg ossl_supported index
     local dhlen supported_sslv2_ciphers ciphers_to_test tls13_ciphers_to_test addcmd temp
     local available
     local id
     local has_dh_bits="$HAS_DH_BITS"

     pr_underline "$(printf -- "%b" "$proto_text")"
     # for local problem if it happens
     out "  "
     if ! "$using_sockets" && ! locally_supported "$proto"; then
          return 0
     fi
     outln

     [[ $(has_server_protocol "${proto:1}") -eq 1 ]] && return 0

     # get a list of all the cipher suites to test
     nr_ciphers=0
     if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               hexc="${TLS_CIPHER_HEXCODE[i]}"
               ciph[nr_ciphers]="${TLS_CIPHER_OSSL_NAME[i]}"
               rfc_ciph[nr_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
               kx[nr_ciphers]="${TLS_CIPHER_KX[i]}"
               enc[nr_ciphers]="${TLS_CIPHER_ENC[i]}"
               export2[nr_ciphers]="${TLS_CIPHER_EXPORT[i]}"
               ciphers_found[nr_ciphers]=false
               sigalg[nr_ciphers]=""
               ossl_supported[nr_ciphers]=${TLS_CIPHER_OSSL_SUPPORTED[i]}
               if "$using_sockets" && ! "$has_dh_bits" && ( [[ ${kx[nr_ciphers]} == "Kx=ECDH" ]] || [[ ${kx[nr_ciphers]} == "Kx=DH" ]] || [[ ${kx[nr_ciphers]} == "Kx=EDH" ]] ); then
                    ossl_supported[nr_ciphers]=false
               fi
               if [[ ${#hexc} -eq 9 ]]; then
                    hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2}"
                    if [[ "${hexc:2:2}" == "00" ]]; then
                         normalized_hexcode[nr_ciphers]="x${hexc:7:2}"
                    else
                         normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}"
                    fi
               else
                    hexc="$(tolower "$hexc")"
                    hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2},${hexc:12:2}"
                    normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}${hexc:12:2}"
               fi
               if ( "$using_sockets" || "${TLS_CIPHER_OSSL_SUPPORTED[i]}" ); then
                    if [[ ${#hexc} -eq 9 ]] && [[ "$proto_text" != SSLv2 ]]; then
                         if [[ "$proto_text" == TLS\ 1.3 ]]; then
                              [[ "${hexc:2:2}" == 13 ]] && nr_ciphers+=1
                         elif [[ "$proto_text" == TLS\ 1.2 ]]; then
                              [[ "${hexc:2:2}" != 13 ]] && nr_ciphers+=1
                         elif [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA256 ]] && [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA384 ]] && \
                              [[ "${TLS_CIPHER_RFC_NAME[i]}" != *_CCM ]] && [[ "${TLS_CIPHER_RFC_NAME[i]}" != *_CCM_8 ]]; then
                              nr_ciphers+=1
                         fi
                    elif [[ ${#hexc} -eq 14 ]] && [[ "$proto_text" == SSLv2 ]]; then
                         sslv2_ciphers+=", ${hexcode[nr_ciphers]}"
                         nr_ciphers+=1
                    fi
               fi
          done
     else # no sockets, openssl!
          # The OpenSSL ciphers function, prior to version 1.1.0, could only understand -ssl2, -ssl3, and -tls1.
          if [[ "$OSSL_NAME" =~ LibreSSL ]]; then
               ossl_ciphers_proto=""
          elif [[ "$proto" == -ssl2 ]] || [[ "$proto" == -ssl3 ]] || \
               [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.0* ]] || [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.1* ]] || \
               [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 3.0.0* ]]; then
               ossl_ciphers_proto="$proto"
          else
               ossl_ciphers_proto="-tls1"
          fi
          while read hexc n ciph[nr_ciphers] sslvers kx[nr_ciphers] auth enc[nr_ciphers] mac export2[nr_ciphers]; do
               if [[ "$proto_text" == TLS\ 1.3 ]]; then
                    [[ "${ciph[nr_ciphers]}" == TLS13* ]] || [[ "${ciph[nr_ciphers]}" == TLS_* ]] || continue
               elif [[ "$proto_text" == "TLS 1.2" ]]; then
                    if [[ "${ciph[nr_ciphers]}" == TLS13* ]] || [[ "${ciph[nr_ciphers]}" == TLS_* ]]; then
                         continue
                    fi
               elif [[ "${ciph[nr_ciphers]}" == *-SHA256 ]] || [[ "${ciph[nr_ciphers]}" == *-SHA384 ]] || \
                    [[ "${ciph[nr_ciphers]}" == *-CCM ]] || [[ "${ciph[nr_ciphers]}" == *-CCM8 ]] || \
                    [[ "${ciph[nr_ciphers]}" =~ CHACHA20-POLY1305 ]]; then
                    continue
               fi
               ciphers_found[nr_ciphers]=false
               normalized_hexcode[nr_ciphers]="$(normalize_ciphercode "$hexc")"
               sigalg[nr_ciphers]=""
               ossl_supported[nr_ciphers]=true
               nr_ciphers+=1
          done < <(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "$ossl_ciphers_proto -V")
     fi

     if [[ "$proto" == "-ssl2" ]]; then
          if "$using_sockets"; then
               sslv2_sockets "${sslv2_ciphers:2}" "true"
               if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
                    supported_sslv2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
                    "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$HOSTCERT")"
                    for (( i=0 ; i<nr_ciphers; i++ )); do
                         if [[ "$supported_sslv2_ciphers" =~ ${normalized_hexcode[i]} ]]; then
                              ciphers_found[i]=true
                              "$SHOW_SIGALGO" && sigalg[i]="$s"
                         fi
                    done
               fi
          else
               $OPENSSL s_client $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY -ssl2 >$TMPFILE 2>$ERRFILE </dev/null
               sclient_connect_successful $? "$TMPFILE"
               if [[ $? -eq 0 ]]; then
                    supported_sslv2_ciphers="$(grep -A 4 "Ciphers common between both SSL endpoints:" $TMPFILE)"
                    "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$TMPFILE")"
                    for (( i=0 ; i<nr_ciphers; i++ )); do
                         if [[ "$supported_sslv2_ciphers" =~ ${ciph[i]} ]]; then
                              ciphers_found[i]=true
                              "$SHOW_SIGALGO" && sigalg[i]="$s"
                         fi
                    done
               fi
          fi
     else # no SSLv2
          nr_ossl_ciphers=0
          for (( i=0; i < nr_ciphers; i++ )); do
               if "${ossl_supported[i]}"; then
                    ciphers_found2[nr_ossl_ciphers]=false
                    ciph2[nr_ossl_ciphers]="${ciph[i]}"
                    index[nr_ossl_ciphers]=$i
                    nr_ossl_ciphers+=1
               fi
          done
          if [[ $nr_ossl_ciphers -eq 0 ]]; then
               num_bundles=0
          else
               # Some servers can't handle a handshake with >= 128 ciphers. So,
               # test cipher suites in bundles of 128 or less.
               num_bundles=$nr_ossl_ciphers/128
               mod_check=$nr_ossl_ciphers%128
               [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

               bundle_size=$nr_ossl_ciphers/$num_bundles
               mod_check=$nr_ossl_ciphers%$num_bundles
               [[ $mod_check -ne 0 ]] && bundle_size+=1
          fi

          for (( bundle=0; bundle < num_bundles; bundle++ )); do
               end_of_bundle=$bundle*$bundle_size+$bundle_size
               [[ $end_of_bundle -gt $nr_ossl_ciphers ]] && end_of_bundle=$nr_ossl_ciphers
               for (( success=0; success==0 ; 1 )); do
                    ciphers_to_test=""
                    tls13_ciphers_to_test=""
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         if ! "${ciphers_found2[i]}"; then
                              if [[ "$proto" == -tls1_3 ]]; then
                                   tls13_ciphers_to_test+=":${ciph2[i]}"
                              else
                                   ciphers_to_test+=":${ciph2[i]}"
                              fi
                         fi
                    done
                    success=1
                    if [[ -n "$ciphers_to_test" ]] || [[ -n "$tls13_ciphers_to_test" ]]; then
                         $OPENSSL s_client $(s_client_options "-cipher "\'${ciphers_to_test:1}\'" -ciphersuites "\'${tls13_ciphers_to_test:1}\'" $proto $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
                         sclient_connect_successful $? "$TMPFILE"
                         if [[ $? -eq 0 ]]; then
                              cipher=$(get_cipher $TMPFILE)
                              if [[ -n "$cipher" ]]; then
                                   success=0
                                   for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                                        [[ "$cipher" == "${ciph2[i]}" ]] && ciphers_found2[i]=true && break
                                   done
                                   i=${index[i]}
                                   ciphers_found[i]=true
                                   [[ "$proto_text" == TLS\ 1.3 ]] && kx[i]="$(read_dhtype_from_file $TMPFILE)"
                                   if [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]]; then
                                        dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                                        kx[i]="${kx[i]} $dhlen"
                                   fi
                                   "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                                        sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
                              fi
                         fi
                    fi
               done
          done

          if "$using_sockets"; then
               nr_nonossl_ciphers=0
               for (( i=0; i < nr_ciphers; i++ )); do
                    if ! "${ciphers_found[i]}"; then
                         ciphers_found2[nr_nonossl_ciphers]=false
                         hexcode2[nr_nonossl_ciphers]="${hexcode[i]}"
                         rfc_ciph2[nr_nonossl_ciphers]="${rfc_ciph[i]}"
                         index[nr_nonossl_ciphers]=$i
                         nr_nonossl_ciphers+=1
                    fi
               done
          fi

          if [[ $nr_nonossl_ciphers -eq 0 ]]; then
               num_bundles=0
          else
               # Some servers can't handle a handshake with >= 128 ciphers. So,
               # test cipher suites in bundles of 128 or less.
               num_bundles=$nr_nonossl_ciphers/128
               mod_check=$nr_nonossl_ciphers%128
               [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

               bundle_size=$nr_nonossl_ciphers/$num_bundles
               mod_check=$nr_nonossl_ciphers%$num_bundles
               [[ $mod_check -ne 0 ]] && bundle_size+=1
          fi

          for (( bundle=0; bundle < num_bundles; bundle++ )); do
               end_of_bundle=$bundle*$bundle_size+$bundle_size
               [[ $end_of_bundle -gt $nr_nonossl_ciphers ]] && end_of_bundle=$nr_nonossl_ciphers
               for (( success=0; success==0 ; 1 )); do
                    ciphers_to_test=""
                    for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                         ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode2[i]}"
                    done
                    success=1
                    if [[ -n "$ciphers_to_test" ]]; then
                         if "$SHOW_SIGALGO"; then
                              tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "all"
                         else
                              tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
                         fi
                         if [[ $? -eq 0 ]]; then
                              success=0
                              cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                              for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                                   [[ "$cipher" == "${rfc_ciph2[i]}" ]] && ciphers_found2[i]=true && break
                              done
                              i=${index[i]}
                              ciphers_found[i]=true
                              [[ "$proto_text" == TLS\ 1.3 ]] && kx[i]="$(read_dhtype_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")"
                              if [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]]; then
                                   dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                                   kx[i]="${kx[i]} $dhlen"
                              fi
                              "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && \
                                   sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
                         fi
                    fi
               done
          done
     fi

     for (( i=0 ; i<nr_ciphers; i++ )); do
          if "${ciphers_found[i]}" || "$SHOW_EACH_C"; then
               export=${export2[i]}
               normalized_hexcode[i]="$(tolower "${normalized_hexcode[i]}")"
               neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
               available=""
               if "$SHOW_EACH_C"; then
                    if "${ciphers_found[i]}"; then
                         available="available"
                         pr_cyan "$available"
                    else
                         available="not a/v"
                         pr_deemphasize "$available"
                    fi
               fi
               outln "${sigalg[i]}"
               id="cipher$proto"
               id+="_${normalized_hexcode[i]}"
               fileout "$id" "INFO" "$proto_text  $(neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}") $available"
          fi
     done

     "$using_sockets" && HAS_DH_BITS="$has_dh_bits"
     tmpfile_handle ${FUNCNAME[0]}${proto}.txt
     return 0
#FIXME: no error condition
}

# test for all ciphers per protocol locally configured (w/o distinguishing whether they are good or bad)
run_cipher_per_proto() {
     local proto proto_hex proto_text
     local using_sockets=true

     "$SSL_NATIVE" && using_sockets=false
     "$FAST" && using_sockets=false
     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

     outln
     if "$using_sockets"; then
          pr_headlineln " Testing ciphers per protocol via OpenSSL plus sockets against the server, ordered by encryption strength "
     else
          pr_headlineln " Testing all locally available ciphers per protocol against the server, ordered by encryption strength "
          [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && pr_warning " Cipher mapping not available, doing a fallback to openssl"
          outln
          if ! "$HAS_DH_BITS"; then
               [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && out "."
               prln_warning "    (Your $OPENSSL cannot show DH/ECDH bits)"
          fi
     fi
     outln
     neat_header
     echo -e " -ssl2 22 SSLv2\n -ssl3 00 SSLv3\n -tls1 01 TLS 1\n -tls1_1 02 TLS 1.1\n -tls1_2 03 TLS 1.2\n -tls1_3 04 TLS 1.3" | while read proto proto_hex proto_text; do
          ciphers_by_strength "$proto" "$proto_hex" "$proto_text" "$using_sockets"
     done
     return 0
#FIXME: no error condition
}

# arg1 is an ASCII-HEX encoded SSLv3 or TLS ClientHello.
# arg2: new key_share extension (only present to response to HelloRetryRequest)
# arg3: cookie extension (if needed for response to HelloRetryRequest)
#
# This function may be used to either modify a ClientHello for client simulation
# or to create a second ClientHello in response to a HelloRetryRequest.
# If arg2 is present, then this is a response to a HelloRetryRequest, so the
# function replaces the key_share extension with arg2 and adds the cookie
# extension, if present.
# If arg2 is not present, then this is an initial ClientHello for client simulation.
# In this case, if the provided ClientHello contains a server name extension,
# then either:
#  1) replace it with one corresponding to $SNI; or
#  2) remove it, if $SNI is empty
modify_clienthello() {
     local tls_handshake_ascii="$1"
     local new_key_share="$2" cookie="$3"
     local -i len offset tls_handshake_ascii_len len_all len_clienthello
     local -i len_extensions len_extension
     local tls_content_type tls_version_reclayer handshake_msg_type tls_clientversion
     local tls_random tls_sid tls_cipher_suites tls_compression_methods
     local tls_extensions="" extension_type len_extensions_hex
     local len_servername hexdump_format_str servername_hexstr
     local len_servername_hex len_sni_listlen len_sni_ext
     local tls_client_hello len_clienthello_hex tls_handshake_ascii_len_hex
     local sni_extension_found=false

     tls_handshake_ascii_len=${#tls_handshake_ascii}

     tls_content_type="${tls_handshake_ascii:0:2}"
     tls_version_reclayer="${tls_handshake_ascii:2:4}"
     len_all=$(hex2dec "${tls_handshake_ascii:6:4}")

     handshake_msg_type="${tls_handshake_ascii:10:2}"
     len_clienthello=$(hex2dec "${tls_handshake_ascii:12:6}")
     tls_clientversion="${tls_handshake_ascii:18:4}"
     tls_random="${tls_handshake_ascii:22:64}"
     len=2*$(hex2dec "${tls_handshake_ascii:86:2}")+2
     tls_sid="${tls_handshake_ascii:86:$len}"
     offset=86+$len

     len=2*$(hex2dec "${tls_handshake_ascii:$offset:4}")+4
     tls_cipher_suites="${tls_handshake_ascii:$offset:$len}"
     offset=$offset+$len

     len=2*$(hex2dec "${tls_handshake_ascii:$offset:2}")+2
     tls_compression_methods="${tls_handshake_ascii:$offset:$len}"
     offset=$offset+$len

     if [[ $offset -ge $tls_handshake_ascii_len ]]; then
          # No extensions
          tm_out "$tls_handshake_ascii"
          return 0
     fi

     len_extensions=2*$(hex2dec "${tls_handshake_ascii:$offset:4}")
     offset+=4
     for (( 1; offset < tls_handshake_ascii_len; 1 )); do
          extension_type="${tls_handshake_ascii:$offset:4}"
          offset+=4
          len_extension=2*$(hex2dec "${tls_handshake_ascii:$offset:4}")

          if [[ "$extension_type" == 0000 ]] && [[ -z "$new_key_share" ]]; then
               # If this is an initial ClientHello, then either remove
               # the SNI extension or replace it with the correct server name.
               sni_extension_found=true
               if [[ -n "$SNI" ]]; then
                    # Create a server name extension that corresponds to $SNI
                    len_servername=${#NODE}
                    hexdump_format_str="$len_servername/1 \"%02x\""
                    servername_hexstr=$(printf $NODE | hexdump -v -e "${hexdump_format_str}")
                    # convert lengths we need to fill in from dec to hex:
                    len_servername_hex=$(printf "%02x\n" $len_servername)
                    len_sni_listlen=$(printf "%02x\n" $((len_servername+3)))
                    len_sni_ext=$(printf "%02x\n" $((len_servername+5)))
                    tls_extensions+="000000${len_sni_ext}00${len_sni_listlen}0000${len_servername_hex}${servername_hexstr}"
               fi
               offset+=$len_extension+4
          elif [[ "$extension_type" != 00$KEY_SHARE_EXTN_NR ]] || [[ -z "$new_key_share" ]]; then
               # If this is in response to a HelloRetryRequest, then do
               # not copy over the old key_share extension, but
               # all other extensions should be copied into the new ClientHello.
               offset=$offset-4
               len=$len_extension+8
               tls_extensions+="${tls_handshake_ascii:$offset:$len}"
               offset+=$len
          else
               # This is the key_share extension, and the modified ClientHello
               # is being created in response to a HelloRetryRequest. Replace
               # the existing key_share extension with the new one.
               tls_extensions+="$new_key_share"
               offset+=$len_extension+4
          fi
     done
     tls_extensions+="$cookie"

     if ! "$sni_extension_found" && [[ -z "$new_key_share" ]]; then
          tm_out "$tls_handshake_ascii"
          return 0
     fi

     len_extensions=${#tls_extensions}/2
     len_extensions_hex=$(printf "%02x\n" $len_extensions)
     len2twobytes "$len_extensions_hex"
     tls_extensions="${LEN_STR:0:2}${LEN_STR:4:2}${tls_extensions}"

     tls_client_hello="${tls_clientversion}${tls_random}${tls_sid}${tls_cipher_suites}${tls_compression_methods}${tls_extensions}"
     len_clienthello=${#tls_client_hello}/2
     len_clienthello_hex=$(printf "%02x\n" $len_clienthello)
     len2twobytes "$len_clienthello_hex"
     tls_handshake_ascii="${handshake_msg_type}00${LEN_STR:0:2}${LEN_STR:4:2}${tls_client_hello}"

     tls_handshake_ascii_len=${#tls_handshake_ascii}/2
     tls_handshake_ascii_len_hex=$(printf "%02x\n" $tls_handshake_ascii_len)
     len2twobytes "$tls_handshake_ascii_len_hex"
     tls_handshake_ascii="${tls_content_type}${tls_version_reclayer}${LEN_STR:0:2}${LEN_STR:4:2}${tls_handshake_ascii}"
     tm_out "$tls_handshake_ascii"
     return 0
}

client_simulation_sockets() {
     local -i len i ret=0
     local -i save=0
     local lines clienthello data=""
     local cipher_list_2send=""
     local sock_reply_file2 sock_reply_file3
     local tls_hello_ascii next_packet hello_done=0
     local -i sid_len offset1 offset2

     if [[ "${1:0:4}" == "1603" ]]; then
          clienthello="$(modify_clienthello "$1")"
          TLS_CLIENT_HELLO="${clienthello:10}"
     else
          clienthello="$1"
          TLS_CLIENT_HELLO=""
     fi
     len=${#clienthello}
     for (( i=0; i < len; i=i+2 )); do
          data+=", ${clienthello:i:2}"
     done
     # same as above. If a CIPHER_SUITES string was provided, then check that it is in the ServerHello
     # this appeared 1st in yassl + MySQL (https://github.com/drwetter/testssl.sh/pull/784) but adds
     # robustness to the implementation
     # see also https://github.com/drwetter/testssl.sh/pull/797
     if [[ "${1:0:4}" == "1603" ]]; then
          # Extact list of cipher suites from SSLv3 or later ClientHello
          sid_len=4*$(hex2dec "${data:174:2}")
          offset1=178+$sid_len
          offset2=182+$sid_len
          len=4*$(hex2dec "${data:offset1:2}${data:offset2:2}")-2
          offset1=186+$sid_len
          code2network "$(tolower "${data:offset1:len}")"    # convert CIPHER_SUITES to a "standardized" format
     else
          # Extact list of cipher suites from SSLv2 ClientHello
          len=2*$(hex2dec "${clienthello:12:2}")
          for (( i=22; i < 22+len; i=i+6 )); do
               offset1=$i+2
               offset2=$i+4
               [[ "${clienthello:i:2}" == "00" ]] && cipher_list_2send+=", ${clienthello:offset1:2},${clienthello:offset2:2}"
          done
          code2network "$(tolower "${cipher_list_2send:2}")" # convert CIPHER_SUITES to a "standardized" format
     fi
     cipher_list_2send="$NW_STR"

     fd_socket 5 || return 6
     debugme echo -e "\nsending client hello... "
     socksend_clienthello "${data}"
     sleep $USLEEP_SND

     sockread_serverhello 32768
     tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
     tls_hello_ascii="${tls_hello_ascii%%[!0-9A-F]*}"

     # Check if the response is a HelloRetryRequest.
     resend_if_hello_retry_request "$clienthello" "$tls_hello_ascii"
     ret=$?
     if [[ $ret -eq 2 ]]; then
          tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          tls_hello_ascii="${tls_hello_ascii%%[!0-9A-F]*}"
     elif [[ $ret -eq 1 ]] || [[ $ret -eq 6 ]]; then
          close_socket
          TMPFILE=$SOCK_REPLY_FILE
          tmpfile_handle ${FUNCNAME[0]}.dd
          return $ret
     fi

     if [[ "${tls_hello_ascii:0:1}" != "8" ]]; then
          check_tls_serverhellodone "$tls_hello_ascii" "ephemeralkey"
          hello_done=$?
     fi

     for(( 1 ; hello_done==1; 1 )); do
          if [[ $DEBUG -ge 1 ]]; then
               sock_reply_file2=${SOCK_REPLY_FILE}.2
               mv "$SOCK_REPLY_FILE" "$sock_reply_file2"
          fi

          debugme echo -n "requesting more server hello data... "
          socksend "" $USLEEP_SND
          sockread_serverhello 32768

          next_packet=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          next_packet="${next_packet%%[!0-9A-F]*}"
          if [[ ${#next_packet} -eq 0 ]]; then
               # This shouldn't be necessary. However, it protects against
               # getting into an infinite loop if the server has nothing
               # left to send and check_tls_serverhellodone doesn't
               # correctly catch it.
               [[ $DEBUG -ge 1 ]] && mv "$sock_reply_file2" "$SOCK_REPLY_FILE"
               hello_done=0
          else
               tls_hello_ascii+="$next_packet"
               if [[ $DEBUG -ge 1 ]]; then
                    sock_reply_file3=${SOCK_REPLY_FILE}.3
                    mv "$SOCK_REPLY_FILE" "$sock_reply_file3"    #FIXME: we moved that already
                    mv "$sock_reply_file2" "$SOCK_REPLY_FILE"
                    cat "$sock_reply_file3" >> "$SOCK_REPLY_FILE"
                    rm "$sock_reply_file3"
               fi

               check_tls_serverhellodone "$tls_hello_ascii" "ephemeralkey"
               hello_done=$?
          fi
     done

     debugme echo "reading server hello..."
     if [[ "$DEBUG" -ge 4 ]]; then
          hexdump -C $SOCK_REPLY_FILE | head -6
          echo
     fi
     if [[ "${tls_hello_ascii:0:1}" == "8" ]]; then
          parse_sslv2_serverhello "$SOCK_REPLY_FILE" "false"
          if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
               echo "Protocol  : SSLv2" > "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt"
               DETECTED_TLS_VERSION="0200"
               ret=0
          else
               ret=1
          fi
     else
          parse_tls_serverhello "$tls_hello_ascii" "ephemeralkey" "$cipher_list_2send"
          save=$?

          if [[ $save -eq 0 ]]; then
               send_close_notify "$DETECTED_TLS_VERSION"
          fi

          if [[ $DEBUG -ge 2 ]]; then
               # see https://secure.wand.net.nz/trac/libprotoident/wiki/SSL
               lines=$(count_lines "$(hexdump -C "$SOCK_REPLY_FILE" 2>$ERRFILE)")
               tm_out "  ($lines lines returned)  "
          fi

          # determine the return value for higher level, so that they can tell what the result is
          if [[ $save -eq 1 ]] || [[ $lines -eq 1 ]]; then
               ret=1          # NOT available
          else
               ret=0
          fi
          debugme tmln_out
     fi

     close_socket
     TMPFILE=$SOCK_REPLY_FILE
     tmpfile_handle ${FUNCNAME[0]}.dd
     return $ret
}

run_client_simulation() {
     # Runs browser simulations. Browser capabilities gathered from:
     # https://www.ssllabs.com/ssltest/clients.html on 10 jan 2016
     local names=()
     local short=()
     local protos=()
     local ciphers=()
     local ciphersuites=()
     local tlsvers=()
     local sni=()
     local warning=()
     local handshakebytes=()
     local lowest_protocol=()
     local highest_protocol=()
     local service=()
     local minDhBits=()
     local maxDhBits=()
     local minRsaBits=()
     local maxRsaBits=()
     local minEcdsaBits=()
     local curves=()
     local requiresSha2=()
     local current=()
     local i=0
     local name tls proto cipher temp what_dh bits curve supported_curves
     local has_dh_bits using_sockets=true
     local client_service
     local options
     local -i ret=0
     local jsonID="clientsimulation"
     local client_service=""

     # source the external file
     . "$TESTSSL_INSTALL_DIR/etc/client-simulation.txt" 2>/dev/null
     if [[ $? -ne 0 ]]; then
          prln_local_problem "couldn't find client simulation data in $TESTSSL_INSTALL_DIR/etc/client-simulation.txt"
          return 1
     fi

     "$SSL_NATIVE" && using_sockets=false

     if [[ $SERVICE != "" ]];  then
          client_service="$SERVICE"
     elif [[ -n "$STARTTLS_PROTOCOL" ]]; then
          # Can we take the service from STARTTLS?
          client_service=$(toupper "${STARTTLS_PROTOCOL%s}")    # strip trailing 's' in ftp(s), smtp(s), pop3(s), etc
     elif "$ASSUME_HTTP"; then
          client_service="HTTP"
     else
          outln "Could not determine the protocol, only simulating generic clients."
     fi

     outln
     pr_headline " Running client simulations "
     [[ "$client_service" == HTTP ]] && pr_headline "($client_service) "
     if "$using_sockets"; then
          pr_headlineln "via sockets "
     else
          pr_headline "via openssl "
          prln_warning " -- pls note \"--ssl-native\" will return some false results"
          fileout "$jsonID" "WARN" "You shouldn't run this with \"--ssl-native\" as you will get false results"
          ret=1
     fi
     outln
     debugme echo

     if "$WIDE"; then
          if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]]; then
               out " Browser                      Protocol  Cipher Suite Name (OpenSSL)       "
               ( "$using_sockets" || "$HAS_DH_BITS") && out "Forward Secrecy"
               outln
               out "--------------------------------------------------------------------------"
          else
               out " Browser                      Protocol  Cipher Suite Name (IANA/RFC)                      "
               ( "$using_sockets" || "$HAS_DH_BITS") && out "Forward Secrecy"
               outln
               out "------------------------------------------------------------------------------------------"
          fi
          ( "$using_sockets" || "$HAS_DH_BITS") && out "----------------------"
          outln
     fi
     if ! "$using_sockets"; then
          # We can't use the connectivity checker here as of now the openssl reply is always empty (reason??)
          save_max_ossl_fail=$MAX_OSSL_FAIL
          nr_ossl_fail=$NR_OSSL_FAIL
          MAX_OSSL_FAIL=100
     fi
     for name in "${short[@]}"; do
          if "${current[i]}" || "$ALL_CLIENTS" ; then
               # for ANY we test this service or if the service we determined from STARTTLS matches
               if [[ "${service[i]}" == ANY ]] || [[ "${service[i]}" =~ $client_service ]]; then
                    out " $(printf -- "%-29s" "${names[i]}")"
                    if "$using_sockets" && [[ -n "${handshakebytes[i]}" ]]; then
                         client_simulation_sockets "${handshakebytes[i]}"
                         sclient_success=$?
                         if [[ $sclient_success -eq 0 ]]; then
                              if [[ "0x${DETECTED_TLS_VERSION}" -lt ${lowest_protocol[i]} ]] || \
                                 [[ "0x${DETECTED_TLS_VERSION}" -gt ${highest_protocol[i]} ]]; then
                                   sclient_success=1
                              fi
                              [[ $sclient_success -eq 0 ]] && cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE >$ERRFILE
                         fi
                    else
                         if [[ -n "${curves[i]}" ]]; then
                              # "$OPENSSL s_client" will fail if the -curves option includes any unsupported curves.
                              supported_curves=""
                              for curve in $(colon_to_spaces "${curves[i]}"); do
                                   # Attention! secp256r1 = prime256v1 and secp192r1 = prime192v1
                                   # We need to map two curves here as otherwise handshakes will go wrong if "-curves" are supplied
                                   # https://github.com/openssl/openssl/blob/master/apps/ecparam.c#L221 + ./ssl/t1_lib.c
                                   [[ "$curve" =~ secp256r1 ]] && curve="${curve//secp256r1/prime256v1}"
                                   [[ "$curve" =~ secp192r1 ]] && curve="${curve//secp192r1/prime192v1}"
                                   [[ "$OSSL_SUPPORTED_CURVES" =~ " $curve " ]] && supported_curves+=":$curve"
                              done
                              curves[i]=""
                              [[ -n "$supported_curves" ]] && curves[i]="-curves ${supported_curves:1}"
                         fi
                         options="$(s_client_options "-cipher ${ciphers[i]} -ciphersuites "\'${ciphersuites[i]}\'" ${curves[i]} ${protos[i]} $STARTTLS $BUGS $PROXY -connect $NODEIP:$PORT ${sni[i]}")"
                         debugme echo "$OPENSSL s_client $options  </dev/null"
                         $OPENSSL s_client $options </dev/null >$TMPFILE 2>$ERRFILE
                         sclient_connect_successful $? $TMPFILE
                         sclient_success=$?
                    fi
                    if [[ $sclient_success -eq 0 ]]; then
                         # If an ephemeral DH key was used, check that the number of bits is within range.
                         temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TMPFILE")        # extract line
                         what_dh="${temp%%,*}"
                         bits="${temp##*, }"
                         # formatting
                         curve="${temp#*, }"
                         if [[ "$curve" == $bits ]]; then
                              curve=""
                         else
                              curve="${curve%%,*}"
                         fi
                         bits="${bits/bits/}"
                         bits="${bits// /}"
                         if [[ "$what_dh" == X25519 ]] || [[ "$what_dh" == X448 ]]; then
                              curve="$what_dh"
                              what_dh="ECDH"
                         fi
                         if [[ "$what_dh" == DH ]]; then
                              [[ ${minDhBits[i]} -ne -1 ]] && [[ $bits -lt ${minDhBits[i]} ]] && sclient_success=1
                              [[ ${maxDhBits[i]} -ne -1 ]] && [[ $bits -gt ${maxDhBits[i]} ]] && sclient_success=1
                         fi
                    fi
                    if [[ $sclient_success -ne 0 ]]; then
                         outln "No connection"
                         fileout "${jsonID}-${short[i]}" "INFO" "No connection"
                    else
                         proto=$(get_protocol $TMPFILE)
                         # hack:
                         [[ "$proto" == TLSv1 ]] && proto="TLSv1.0"
                         [[ "$proto" == SSLv3 ]] && proto="SSLv3  "
                         if [[ "$proto" == TLSv1.2 ]] && ( ! "$using_sockets" || [[ -z "${handshakebytes[i]}" ]] ); then
                              # OpenSSL reports TLS1.2 even if the connection is TLS1.1 or TLS1.0. Need to figure out which one it is...
                              for tls in ${tlsvers[i]}; do
                                   # If the handshake data includes TLS 1.3 we need to remove it, otherwise the
                                   # simulation will fail with # 'Oops: openssl s_client connect problem'
                                   # before/after trying another protocol. We only print a warning it in debug mode
                                   # as otherwise we would need e.g. handle the curves in a similar fashion -- not
                                   # to speak about ciphers
                                   if [[ $tls =~ 1_3 ]] && ! "$HAS_TLS13"; then
                                        debugme pr_local_problem "TLS 1.3 not supported, "
                                        continue
                                   fi
                                   options="$(s_client_options "$tls -cipher ${ciphers[i]} -ciphersuites "\'${ciphersuites[i]}\'" ${curves[i]} $STARTTLS $BUGS $PROXY -connect $NODEIP:$PORT ${sni[i]}")"
                                   debugme echo "$OPENSSL s_client $options  </dev/null"
                                   $OPENSSL s_client $options  </dev/null >$TMPFILE 2>$ERRFILE
                                   sclient_connect_successful $? $TMPFILE
                                   sclient_success=$?
                                   if [[ $sclient_success -eq 0 ]]; then
                                        case "$tls" in
                                             "-tls1_2") break ;;
                                             "-tls1_1") proto="TLSv1.1"
                                                        break ;;
                                             "-tls1")   proto="TLSv1.0"
                                                        break ;;
                                        esac
                                   fi
                              done
                         fi
                         cipher=$(get_cipher $TMPFILE)
                         if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && ( [[ "$cipher" == TLS_* ]] || [[ "$cipher" == SSL_* ]] ); then
                              cipher="$(rfc2openssl "$cipher")"
                              [[ -z "$cipher" ]] && cipher=$(get_cipher $TMPFILE)
                         elif [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]] && [[ "$cipher" != TLS_* ]] && [[ "$cipher" != SSL_* ]]; then
                              cipher="$(openssl2rfc "$cipher")"
                              [[ -z "$cipher" ]] && cipher=$(get_cipher $TMPFILE)
                         fi
                         out "$proto "
                         "$WIDE" && out "  "
                         if [[ "$COLOR" -le 2 ]]; then
                              out "$cipher"
                         else
                              pr_cipher_quality "$cipher"
                         fi
                         if "$WIDE"; then
                              if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]]; then
                                   for (( j=${#cipher}; j < 34; j++ )); do
                                        out " "
                                   done
                              else
                                   for (( j=${#cipher}; j < 50; j++ )); do
                                        out " "
                                   done
                              fi
                         fi
                         if [[ -n "$what_dh" ]]; then
                              [[ -n "$curve" ]] && curve="($curve)"
                              "$WIDE" || out ", "
                              if [[ "$what_dh" == ECDH ]]; then
                                   pr_ecdh_quality "$bits" "$(printf -- "%-12s" "$bits bit $what_dh") $curve"
                              else
                                   pr_dh_quality "$bits" "$(printf -- "%-12s" "$bits bit $what_dh") $curve"
                              fi
                         else
                              if "$HAS_DH_BITS" || ( "$using_sockets" && [[ -n "${handshakebytes[i]}" ]] ); then
                                   "$WIDE" || out ", "
                                   out "No FS"
                              fi
                         fi
                         outln
                         if [[ -n "${warning[i]}" ]]; then
                              out "                            "
                              outln "${warning[i]}"
                         fi
                         fileout "${jsonID}-${short[i]}" "INFO" "$proto $cipher  ${warning[i]}"
                         debugme cat $TMPFILE
                    fi
               fi   # correct service?
          fi   #current?
          ((i++))
     done
     if ! "$using_sockets"; then
          # restore from above
          MAX_OSSL_FAIL=$save_max_ossl_fail
          NR_OSSL_FAIL=$nr_ossl_fail
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}

# generic function whether $1 is supported by s_client ($2: string to display, currently nowhere being used)
#
locally_supported() {
     [[ -n "$2" ]] && out "$2 "
     if $OPENSSL s_client "$1" -connect x 2>&1 | grep -aq "unknown option"; then
          prln_local_problem "$OPENSSL doesn't support \"s_client $1\""
          return 7
     fi
     return 0
}


# The protocol check in run_protocols needs to be redone. The using_sockets part there kind of sucks.
# 1) we need to have a variable where the results are being stored so that every other test doesn't have to do this again
#   --> we have that but certain information like "downgraded" are not being passed. That's not ok for run_protocols()/
#   for all other functions we can use it
# 2) the code is old and one can do that way better
# We should do what's available and faster (openssl vs. sockets). Keep in mind that the socket reply for SSLv2 returns the number # of ciphers!
#
# arg1: -ssl2|-ssl3|-tls1|-tls1_1|-tls1_2|-tls1_3
#
run_prototest_openssl() {
     local -i ret=0
     local protos proto

     # check whether the protocol being tested is supported by $OPENSSL
     $OPENSSL s_client "$1" -connect x 2>&1 | grep -aq "unknown option" && return 7
     case "$1" in
          -ssl2) protos="-ssl2" ;;
          -ssl3) protos="-ssl3" ;;
          -tls1) protos="-no_tls1_2 -no_tls1_1 -no_ssl2"; "$HAS_TLS13" && protos+=" -no_tls1_3" ;;
          -tls1_1) protos="-no_tls1_2 -no_ssl2"; "$HAS_TLS13" && protos+=" -no_tls1_3" ;;
          -tls1_2) protos="-no_ssl2"; "$HAS_TLS13" && protos+=" -no_tls1_3" ;;
          -tls1_3) protos="" ;;
     esac
     $OPENSSL s_client $(s_client_options "-state $protos $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>&1 </dev/null
     sclient_connect_successful $? $TMPFILE
     ret=$?
     debugme grep -E "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
     if [[ $ret -ne 0 ]]; then
          if grep -aq "no cipher list" $TMPFILE; then
               ret=5       # <--- important indicator for SSL2 (maybe others, too)
          else
               # try again without $PROXY
               $OPENSSL s_client $(s_client_options "-state $protos $STARTTLS $BUGS -connect $NODEIP:$PORT $SNI") >$TMPFILE 2>&1 </dev/null
               sclient_connect_successful $? $TMPFILE
               ret=$?
               debugme grep -E "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
               grep -aq "no cipher list" $TMPFILE && ret=5       # <--- important indicator for SSL2 (maybe others, too)
          fi
     fi
     if [[ $ret -eq 0 ]]; then
          proto="$(get_protocol "$TMPFILE")"
          proto=${proto/\./_}
          proto=${proto/v/}
          proto="-$(tolower $proto)"
          [[ "$proto" != $1 ]] && ret=2
          case "$proto" in
               -ssl3) DETECTED_TLS_VERSION="0300" ;;
               -tls1) DETECTED_TLS_VERSION="0301" ;;
               -tls1_1) DETECTED_TLS_VERSION="0302" ;;
               -tls1_2) DETECTED_TLS_VERSION="0303" ;;
               -tls1_3) DETECTED_TLS_VERSION="0304" ;;
          esac
     fi
     tmpfile_handle ${FUNCNAME[0]}$1.txt
     return $ret

     # 0: offered
     # 1: not offered
     # 2: downgraded
     # 5: protocol ok, but no cipher
     # 7: no local support
}

# Idempotent function to add SSL/TLS protocols. It should accelerate testing.
# PROTOS_OFFERED can be e.g. "ssl2:no ssl3:no tls1_2:yes" which means that
# SSLv2 and SSLv3 was tested but not available, TLS 1.2 was tested and available
# TLS 1.0 and TLS 1.2 not tested yet
#
# arg1: protocol
# arg2: available (yes) or not (no)
add_tls_offered() {
     if [[ "$PROTOS_OFFERED" =~ $1: ]]; then
          # the ":" is mandatory here (and @ other places), otherwise e.g. tls1 will match tls1_2
          :
     else
           PROTOS_OFFERED+="${1}:$2 "
     fi
}

# function which checks whether SSLv2 - TLS 1.2 is being offered, see add_tls_offered()
# arg1:    protocol string or hex code for TLS protocol
# echos:   0 if proto known being offered, 1: known not being offered, 2: we don't know yet whether proto is being offered
# return value is always zero
has_server_protocol() {
     local proto
     local proto_val_pair

     case "$1" in
          04) proto="tls1_3" ;;
          03) proto="tls1_2" ;;
          02) proto="tls1_1" ;;
          01) proto="tls1" ;;
          00) proto="ssl3" ;;
           *) proto="$1" ;;
     esac

     if [[ "$PROTOS_OFFERED" =~ $proto: ]]; then
          for proto_val_pair in $PROTOS_OFFERED; do
               if [[ $proto_val_pair =~ $proto: ]]; then
                    if [[ ${proto_val_pair#*:} == yes ]]; then
                         echo 0
                         return 0
                    else
                         echo 1
                         return 0
                    fi
               fi
          done
     else
          # if empty echo 2, hinting to the caller to check at additional cost/connect
          echo 2
          return 0
     fi
}


# the protocol check needs to be revamped. It sucks, see above
run_protocols() {
     local using_sockets=true
     local supported_no_ciph1="supported but couldn't detect a cipher (may need debugging)"
     local supported_no_ciph2="supported but couldn't detect a cipher"
     local latest_supported=""  # version.major and version.minor of highest version supported by the server
     local detected_version_string latest_supported_string
     local key_share_extn_nr="$KEY_SHARE_EXTN_NR"
     local lines nr_ciphers_detected
     local tls13_ciphers_to_test=""
     local i drafts_offered=""  drafts_offered_str="" supported_versions debug_recomm=""
     local tls12_detected_version
     local -i ret=0 ret_val_ssl3 ret_val_tls1 ret_val_tls11 ret_val_tls12=0 ret_val_tls13=0
     local offers_tls13=false
     local jsonID="SSLv2"

     outln; pr_headline " Testing protocols "

     if "$SSL_NATIVE"; then
          using_sockets=false
          prln_underline "via native openssl"
     else
          using_sockets=true
          if [[ -n "$STARTTLS" ]]; then
               prln_underline "via sockets "
          else
               prln_underline "via sockets except NPN+ALPN "
          fi
     fi
     outln
     [[ "$DEBUG" -le 1 ]] && debug_recomm=", rerun with DEBUG>=2 or --ssl-native"

     pr_bold " SSLv2      ";
     if ! "$SSL_NATIVE"; then
          sslv2_sockets
          case $? in
               6) # couldn't open socket
                    prln_fixme "couldn't open socket"
                    fileout "$jsonID" "WARN" "couldn't be tested, socket problem"
                    ((ret++))
                    ;;
               7) # strange reply, couldn't convert the cipher spec length to a hex number
                    pr_cyan "strange v2 reply "
                    outln "$debug_recomm"
                    [[ $DEBUG -ge 3 ]] && hexdump -C "$TEMPDIR/$NODEIP.sslv2_sockets.dd" | head -1
                    fileout "$jsonID" "WARN" "received a strange SSLv2 reply (rerun with DEBUG>=2)"
                    ;;
               1) # no sslv2 server hello returned, like in openlitespeed which returns HTTP!
                    prln_svrty_best "not offered (OK)"
                    fileout "$jsonID" "OK" "not offered"
                    add_tls_offered ssl2 no
                    ;;
               0) # reset
                    prln_svrty_best "not offered (OK)"
                    fileout "$jsonID" "OK" "not offered"
                    add_tls_offered ssl2 no
                    ;;
               4)   out "likely "; pr_svrty_best "not offered (OK), "
                    fileout "$jsonID" "OK" "likely not offered"
                    add_tls_offered ssl2 no
                    pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
                    fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
                    ;;
               3)   lines=$(count_lines "$(hexdump -C "$TEMPDIR/$NODEIP.sslv2_sockets.dd" 2>/dev/null)")
                    [[ "$DEBUG" -ge 2 ]] && tm_out "  ($lines lines)  "
                    if [[ "$lines" -gt 1 ]]; then
                         nr_ciphers_detected=$((V2_HELLO_CIPHERSPEC_LENGTH / 3))
                         add_tls_offered ssl2 yes
                         if [[ 0 -eq "$nr_ciphers_detected" ]]; then
                              prln_svrty_high "supported but couldn't detect a cipher and vulnerable to CVE-2015-3197 ";
                              fileout "$jsonID" "HIGH" "offered, no cipher" "CVE-2015-3197" "CWE-310"
                         else
                              pr_svrty_critical "offered (NOT ok), also VULNERABLE to DROWN attack";
                              outln " -- $nr_ciphers_detected ciphers"
                              fileout "$jsonID" "CRITICAL" "vulnerable with $nr_ciphers_detected ciphers"
                         fi
                    fi
                    ;;
               *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
                    ((ret++))
                    ;;
          esac
          debugme tmln_out
     else
          run_prototest_openssl "-ssl2"
          case $? in
               0)   prln_svrty_critical   "offered (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "offered"
                    add_tls_offered ssl2 yes
                    ;;
               1)   prln_svrty_best "not offered (OK)"
                    fileout "$jsonID" "OK" "not offered"
                    add_tls_offered ssl2 no
                    ;;
               5)   prln_svrty_high "CVE-2015-3197: $supported_no_ciph2";
                    fileout "$jsonID" "HIGH" "offered, no cipher" "CVE-2015-3197" "CWE-310"
                    add_tls_offered ssl2 yes
                    ;;
               7)   prln_local_problem "$OPENSSL doesn't support \"s_client -ssl2\""
                    fileout "$jsonID" "INFO" "not tested due to lack of local support"
                    ((ret++))
                    ;;
          esac
     fi

     pr_bold " SSLv3      ";
     jsonID="SSLv3"
     if [[ $(has_server_protocol ssl3) -eq 0 ]]; then
          ret_val_ssl3=0
     elif "$using_sockets"; then
          tls_sockets "00" "$TLS_CIPHER"
          ret_val_ssl3=$?
     else
          run_prototest_openssl "-ssl3"
          ret_val_ssl3=$?
     fi
     case $ret_val_ssl3 in
          0)   prln_svrty_high "offered (NOT ok)"
               fileout "$jsonID" "HIGH" "offered"
               if "$using_sockets" || "$HAS_SSL3"; then
                    latest_supported="0300"
                    latest_supported_string="SSLv3"
               fi
               add_tls_offered ssl3 yes
               ;;
          1)   prln_svrty_best "not offered (OK)"
               fileout "$jsonID" "OK" "not offered"
               add_tls_offered ssl3 no
               ;;
          2)   if [[ "$DETECTED_TLS_VERSION" == 03* ]]; then
                    detected_version_string="TLSv1.$((0x$DETECTED_TLS_VERSION-0x0301))"
                    prln_svrty_critical "server responded with higher version number ($detected_version_string) than requested by client (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "server responded with higher version number ($detected_version_string) than requested by client"
               else
                    if [[ ${#DETECTED_TLS_VERSION} -eq 4 ]]; then
                         prln_svrty_critical "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2} (NOT ok)"
                         fileout "$jsonID" "CRITICAL" "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2}"
                    else
                         prln_svrty_medium "strange, server ${DETECTED_TLS_VERSION}"
                         fileout "$jsonID" "MEDIUM" "strange, server ${DETECTED_TLS_VERSION}"
                         ((ret++))
                    fi
               fi
               ;;
          3)   pr_svrty_best "not offered (OK), "
               fileout "$jsonID" "OK" "not offered"
               add_tls_offered ssl3 no
               pr_warning "SSL downgraded to STARTTLS plaintext"; outln
               fileout "$jsonID" "WARN" "SSL downgraded to STARTTLS plaintext"
               ;;
          4)   out "likely "; pr_svrty_best "not offered (OK), "
               fileout "$jsonID" "OK" "not offered"
               add_tls_offered ssl3 no
               pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
               fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
               ;;
          5)   pr_svrty_high "$supported_no_ciph1"               # protocol detected but no cipher --> comes from run_prototest_openssl
               fileout "$jsonID" "HIGH" "$supported_no_ciph1"
               add_tls_offered ssl3 yes
               ;;
          7)   if "$using_sockets" ; then
                    # can only happen in debug mode
                    pr_warning "strange reply, maybe a client side problem with SSLv3"; outln "$debug_recomm"
               else
                    prln_local_problem "$OPENSSL doesn't support \"s_client -ssl3\""
                    fileout "$jsonID" "WARN" "not tested due to lack of local support"
               fi
               ;;
          *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
               ((ret++))
               ;;
     esac

     pr_bold " TLS 1      ";
     jsonID="TLS1"
     if [[ $(has_server_protocol tls1) -eq 0 ]]; then
          ret_val_tls1=0
     elif "$using_sockets"; then
          tls_sockets "01" "$TLS_CIPHER"
          ret_val_tls1=$?
     else
          run_prototest_openssl "-tls1"
          ret_val_tls1=$?
     fi
     case $ret_val_tls1 in
          0)   pr_svrty_low "offered" ; outln " (deprecated)"
               fileout "$jsonID" "LOW" "offered (deprecated)"
               latest_supported="0301"
               latest_supported_string="TLSv1.0"
               add_tls_offered tls1 yes
               ;;                                                # nothing wrong with it -- per se
          1)   out "not offered"
               add_tls_offered tls1 no
               if [[ -z $latest_supported ]]; then
                    outln
                    fileout "$jsonID" "INFO" "not offered"       # neither good or bad
               else
                    prln_svrty_critical " -- connection failed rather than downgrading to $latest_supported_string (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "connection failed rather than downgrading to $latest_supported_string"
               fi
               ;;
          2)   pr_svrty_medium "not offered"
               add_tls_offered tls1 no
               if [[ "$DETECTED_TLS_VERSION" == 0300 ]]; then
                    [[ $DEBUG -ge 1 ]] && tm_out " -- downgraded"
                    outln
                    fileout "$jsonID" "MEDIUM" "not offered, and downgraded to SSL"
               elif [[ "$DETECTED_TLS_VERSION" == 03* ]]; then
                    detected_version_string="TLSv1.$((0x$DETECTED_TLS_VERSION-0x0301))"
                    prln_svrty_critical " -- server responded with higher version number ($detected_version_string) than requested by client"
                    fileout "$jsonID" "CRITICAL" "server responded with higher version number ($detected_version_string) than requested by client"
               else
                    if [[ ${#DETECTED_TLS_VERSION} -eq 4 ]]; then
                         prln_svrty_critical "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2} (NOT ok)"
                         fileout "$jsonID" "CRITICAL" "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2}"
                    else
                         prln_svrty_medium " -- strange, server ${DETECTED_TLS_VERSION}"
                         fileout "$jsonID" "MEDIUM" "strange, server ${DETECTED_TLS_VERSION}"
                    fi
               fi
               ;;
          3)   out "not offered, "
               fileout "$jsonID" "OK" "not offered"
               add_tls_offered tls1 no
               pr_warning "TLS downgraded to STARTTLS plaintext"; outln
               fileout "$jsonID" "WARN" "TLS downgraded to STARTTLS plaintext"
               ;;
          4)   out "likely not offered, "
               fileout "$jsonID" "INFO" "likely not offered"
               add_tls_offered tls1 no
               pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
               fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
               ;;
          5)   outln "$supported_no_ciph1"                                 # protocol detected but no cipher --> comes from run_prototest_openssl
               fileout "$jsonID" "INFO" "$supported_no_ciph1"
               add_tls_offered tls1 yes
               ;;
          7)   if "$using_sockets" ; then
                    # can only happen in debug mode
                    pr_warning "strange reply, maybe a client side problem with TLS 1.0"; outln "$debug_recomm"
               else
                    prln_local_problem "$OPENSSL doesn't support \"s_client -tls1\""
                    fileout "$jsonID" "WARN" "not tested due to lack of local support"
               fi
               ((ret++))
               ;;
          *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
               ((ret++))
               ;;
     esac

     pr_bold " TLS 1.1    ";
     jsonID="TLS1_1"
     if [[ $(has_server_protocol tls1_1) -eq 0 ]]; then
          ret_val_tls11=0
     elif "$using_sockets"; then
          tls_sockets "02" "$TLS_CIPHER"
          ret_val_tls11=$?
     else
          run_prototest_openssl "-tls1_1"
          ret_val_tls11=$?
     fi
     case $ret_val_tls11 in
          0)   pr_svrty_low "offered" ; outln " (deprecated)"
               fileout "$jsonID" "LOW" "offered (deprecated)"
               latest_supported="0302"
               latest_supported_string="TLSv1.1"
               add_tls_offered tls1_1 yes
               ;;                                                # nothing wrong with it
          1)   out "not offered"
               add_tls_offered tls1_1 no
               if [[ -z $latest_supported ]]; then
                    outln
                    fileout "$jsonID" "INFO" "is not offered"    # neither good or bad
               else
                    prln_svrty_critical " -- connection failed rather than downgrading to $latest_supported_string"
                    fileout "$jsonID" "CRITICAL" "connection failed rather than downgrading to $latest_supported_string"
               fi
               ;;
          2)   out "not offered"
               add_tls_offered tls1_1 no
               if [[ "$DETECTED_TLS_VERSION" == "$latest_supported" ]]; then
                    [[ $DEBUG -ge 1 ]] && tm_out " -- downgraded"
                    outln
                    fileout "$jsonID" "CRITICAL" "TLSv1.1 is not offered, and downgraded to a weaker protocol"
               elif [[ "$DETECTED_TLS_VERSION" == 0300 ]] && [[ "$latest_supported" == 0301 ]]; then
                    prln_svrty_critical " -- server supports TLSv1.0, but downgraded to SSLv3 (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "not offered, and downgraded to SSLv3 rather than TLSv1.0"
               elif [[ "$DETECTED_TLS_VERSION" == 03* ]] && [[ 0x$DETECTED_TLS_VERSION -gt 0x0302 ]]; then
                    detected_version_string="TLSv1.$((0x$DETECTED_TLS_VERSION-0x0301))"
                    prln_svrty_critical " -- server responded with higher version number ($detected_version_string) than requested by client (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "not offered, server responded with higher version number ($detected_version_string) than requested by client"
               else
                    if [[ ${#DETECTED_TLS_VERSION} -eq 4 ]]; then
                         prln_svrty_critical "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2} (NOT ok)"
                         fileout "$jsonID" "CRITICAL" "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2}"
                    else
                         prln_svrty_medium " -- strange, server ${DETECTED_TLS_VERSION}"
                         fileout "$jsonID" "MEDIUM" "strange, server ${DETECTED_TLS_VERSION}"
                    fi
               fi
               ;;
          3)   out "not offered, "
               fileout "$jsonID" "OK" "not offered"
               add_tls_offered tls1_1 no
               pr_warning "TLS downgraded to STARTTLS plaintext"; outln
               fileout "$jsonID" "WARN" "TLS downgraded to STARTTLS plaintext"
               ;;
          4)   out "likely not offered, "
               fileout "$jsonID" "INFO" "is not offered"
               add_tls_offered tls1_1 no
               pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
               fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
               ;;
          5)   outln "$supported_no_ciph1"                       # protocol detected but no cipher --> comes from run_prototest_openssl
               fileout "$jsonID" "INFO" "$supported_no_ciph1"
               add_tls_offered tls1_1 yes
               ;;
          7)   if "$using_sockets" ; then
                    # can only happen in debug mode
                    pr_warning "strange reply, maybe a client side problem with TLS 1.1"; outln "$debug_recomm"
               else
                    prln_local_problem "$OPENSSL doesn't support \"s_client -tls1_1\""
                    fileout "$jsonID" "WARN" "not tested due to lack of local support"
               fi
               ((ret++))
               ;;
          *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
               ((ret++))
               ;;
     esac

     # Now, we are doing a basic/pre test for TLS 1.2 and 1.3 in order not to penalize servers (medium)
     # running TLS 1.3 only when TLS 1.2 is not offered.  0 and 5 are the return codes for
     # TLS 1.3 support (kind of, including deprecated pre-versions of TLS 1.3)
     if [[ $(has_server_protocol tls1_2) -eq 0 ]]; then
          ret_val_tls12=0
     elif "$using_sockets"; then
          tls_sockets "03" "$TLS12_CIPHER"
          ret_val_tls12=$?
          tls12_detected_version="$DETECTED_TLS_VERSION"
     else
          run_prototest_openssl "-tls1_2"
          ret_val_tls12=$?
          tls12_detected_version="$DETECTED_TLS_VERSION"
     fi

     if [[ $(has_server_protocol tls1_3) -eq 0 ]]; then
          ret_val_tls13=0
     elif "$using_sockets"; then
          # Need to ensure that at most 128 ciphers are included in ClientHello.
          # If the TLSv1.2 test in determine_optimal_sockets_params()  was successful,
          # then use the 5 TLSv1.3 ciphers plus the cipher selected in the TLSv1.2 test.
          # If the TLSv1.2 test was not successful, then just use the 5 TLSv1.3 ciphers
          # plus the list of ciphers used in all of the previous tests ($TLS_CIPHER).
          if [[ -n "$TLS12_CIPHER_OFFERED" ]]; then
               tls13_ciphers_to_test="$TLS13_CIPHER, $TLS12_CIPHER_OFFERED, 00,ff"
          else
               tls13_ciphers_to_test="$TLS13_CIPHER,$TLS_CIPHER"
          fi
          tls_sockets "04" "$tls13_ciphers_to_test"
          ret_val_tls13=$?
     else
          run_prototest_openssl "-tls1_3"
          ret_val_tls13=$?
     fi
     if [[ $ret_val_tls13 -eq 0 ]] || [[ $ret_val_tls13 -eq 5 ]]; then
          offers_tls13=true             # This variable comes in handy for further if statements below
     fi
     # Done with pretesting TLS 1.2 and 1.3.

     pr_bold " TLS 1.2    ";
     jsonID="TLS1_2"
     case $ret_val_tls12 in
          0)   prln_svrty_best "offered (OK)"
               fileout "$jsonID" "OK" "offered"
               latest_supported="0303"
               latest_supported_string="TLSv1.2"
               add_tls_offered tls1_2 yes
               ;;                                                     # GCM cipher in TLS 1.2: very good!
          1)   add_tls_offered tls1_2 no
               if "$offers_tls13"; then
                    out "not offered"
               else
                    pr_svrty_medium "not offered"
               fi
               if [[ -z $latest_supported ]]; then
                    outln
                    if "$offers_tls13"; then
                         fileout "$jsonID" "INFO" "not offered"
                    else
                         fileout "$jsonID" "MEDIUM" "not offered"     # TLS 1.3, no TLS 1.2 --> no GCM, penalty
                    fi
               else
                    prln_svrty_critical " -- connection failed rather than downgrading to $latest_supported_string"
                    fileout "$jsonID" "CRITICAL" "connection failed rather than downgrading to $latest_supported_string"
               fi
               ;;
          2)   add_tls_offered tls1_2 no
               pr_svrty_medium "not offered and downgraded to a weaker protocol"
               if [[ "$tls12_detected_version" == 0300 ]]; then
                    detected_version_string="SSLv3"
               elif [[ "$tls12_detected_version" == 03* ]]; then
                    detected_version_string="TLSv1.$((0x$tls12_detected_version-0x0301))"
               fi
               if [[ "$tls12_detected_version" == "$latest_supported" ]]; then
                    outln
                    fileout "$jsonID" "MEDIUM" "not offered and downgraded to a weaker protocol"
               elif [[ "$tls12_detected_version" == 03* ]] && [[ 0x$tls12_detected_version -lt 0x$latest_supported ]]; then
                    prln_svrty_critical " -- server supports $latest_supported_string, but downgraded to $detected_version_string"
                    fileout "$jsonID" "CRITICAL" "not offered, and downgraded to $detected_version_string rather than $latest_supported_string"
               elif [[ "$tls12_detected_version" == 03* ]] && [[ 0x$tls12_detected_version -gt 0x0303 ]]; then
                    prln_svrty_critical " -- server responded with higher version number ($detected_version_string) than requested by client"
                    fileout "$jsonID" "CRITICAL" "not offered, server responded with higher version number ($detected_version_string) than requested by client"
               else
                    if [[ ${#tls12_detected_version} -eq 4 ]]; then
                         prln_svrty_critical "server responded with version number ${tls12_detected_version:0:2}.${tls12_detected_version:2:2} (NOT ok)"
                         fileout "$jsonID" "CRITICAL" "server responded with version number ${tls12_detected_version:0:2}.${tls12_detected_version:2:2}"
                    else
                         prln_svrty_medium " -- strange, server ${tls12_detected_version}"
                         fileout "$jsonID" "MEDIUM" "strange, server ${tls12_detected_version}"
                    fi
               fi
               ;;
           3)  out "not offered, "
               fileout "$jsonID" "INFO" "not offered"
               add_tls_offered tls1_2 no
               pr_warning "TLS downgraded to STARTTLS plaintext"; outln
               fileout "$jsonID" "WARN" "TLS downgraded to STARTTLS plaintext"
               ;;
           4)  out "likely "; pr_svrty_medium "not offered, "
               fileout "$jsonID" "MEDIUM" "not offered"
               add_tls_offered tls1_2 no
               pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
               fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
               ;;
           5)  outln "$supported_no_ciph1"                  # protocol detected, but no cipher --> comes from run_prototest_openssl
               fileout "$jsonID" "INFO" "$supported_no_ciph1"
               add_tls_offered tls1_2 yes
               ;;
           7)  if "$using_sockets" ; then
                    # can only happen in debug mode
                    pr_warning "strange reply, maybe a client side problem with TLS 1.2"; outln "$debug_recomm"
               else
                    prln_local_problem "$OPENSSL doesn't support \"s_client -tls1_2\""
                    fileout "$jsonID" "WARN" "not tested due to lack of local support"
               fi
               ((ret++))
               ;;
          *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
               ((ret++))
               ;;
     esac

     pr_bold " TLS 1.3    ";
     jsonID="TLS1_3"
     case $ret_val_tls13 in
          0)   if ! "$using_sockets"; then
                    prln_svrty_best "offered (OK)"
                    fileout "$jsonID" "OK" "offered"
               else
                    # If TLS 1.3 is offered, then its support was detected
                    # by determine_optimal_sockets_params().
                    if [[ $(has_server_protocol tls1_3_rfc8446) -eq 0 ]]; then
                         drafts_offered+=" 0304 "
                    else
                         for i in 1C 1B 1A 19 18 17 16 15 14 13 12; do
                              if [[ $(has_server_protocol tls1_3_draft$(hex2dec "$i")) -eq 0 ]]; then
                                   drafts_offered+=" 7F$i "
                                   break
                              fi
                         done
                    fi
                    KEY_SHARE_EXTN_NR="28"
                    while true; do
                         supported_versions=""
                         for i in 16 15 14 13 12; do
                              [[ "$drafts_offered" =~ \ 7F$i\  ]] || supported_versions+=",7f,$i"
                         done
                         [[ -z "$supported_versions" ]] && break
                         supported_versions="00, 2b, 00, $(printf "%02x" $((${#supported_versions}/3+1))), $(printf "%02x" $((${#supported_versions}/3))) $supported_versions"
                         tls_sockets "04" "$TLS13_CIPHER" "" "$supported_versions"
                         [[ $? -eq 0 ]] || break
                         if [[ "${TLS_SERVER_HELLO:8:3}" == 7F1 ]]; then
                              drafts_offered+=" ${TLS_SERVER_HELLO:8:4} "
                         else
                              for i in 16 15 14 13 12; do
                                   if [[ "$TLS_SERVER_HELLO" =~ 002B00027F$i ]]; then
                                        drafts_offered+=" 7F$i "
                                        break
                                   fi
                              done
                         fi
                    done
                    KEY_SHARE_EXTN_NR="33"
                    while true; do
                         supported_versions=""
                         for i in 1C 1B 1A 19 18 17; do
                              [[ "$drafts_offered" =~ \ 7F$i\  ]] || supported_versions+=",7f,$i"
                         done
                         [[ "$drafts_offered" =~ \ 0304\  ]] || supported_versions+=",03,04"
                         [[ -z "$supported_versions" ]] && break
                         supported_versions="00, 2b, 00, $(printf "%02x" $((${#supported_versions}/3+1))), $(printf "%02x" $((${#supported_versions}/3))) $supported_versions"
                         tls_sockets "04" "$TLS13_CIPHER" "" "$supported_versions"
                         [[ $? -eq 0 ]] || break
                         if [[ "$TLS_SERVER_HELLO" =~ 002B00020304 ]]; then
                              drafts_offered+=" 0304 "
                         else
                              for i in 1C 1B 1A 19 18 17; do
                                   if [[ "$TLS_SERVER_HELLO" =~ 002B00027F$i ]]; then
                                        drafts_offered+=" 7F$i "
                                        break
                                   fi
                              done
                         fi
                    done
                    KEY_SHARE_EXTN_NR="$key_share_extn_nr"
                    if [[ -n "$drafts_offered" ]]; then
                         for i in 1C 1B 1A 19 18 17 16 15 14 13 12; do
                              if [[ "$drafts_offered" =~ \ 7F$i\  ]]; then
                                   [[ -n "$drafts_offered_str" ]] && drafts_offered_str+=", "
                                   drafts_offered_str+="draft $(printf "%d" 0x$i)"
                              fi
                         done
                         if [[ "$drafts_offered" =~ \ 0304\  ]]; then
                              [[ -n "$drafts_offered_str" ]] && drafts_offered_str+=", "
                              drafts_offered_str+="final"
                         fi
                         if [[ "$drafts_offered" =~ \ 0304\  ]]; then
                              pr_svrty_best "offered (OK)"; outln ": $drafts_offered_str"
                              fileout "$jsonID" "OK" "offered with $drafts_offered_str"
                         else
                              out "offered (OK)"; outln ": $drafts_offered_str"
                              fileout "$jsonID" "INFO" "offered with $drafts_offered_str"
                         fi
                    else
                         pr_warning "Unexpected results"; outln "$debug_recomm"
                         fileout "$jsonID" "WARN" "unexpected results"
                    fi
               fi
               latest_supported="0304"
               latest_supported_string="TLSv1.3"
               add_tls_offered tls1_3 yes
               ;;
          1)   pr_svrty_low "not offered"
               if [[ -z $latest_supported ]]; then
                    outln
                    fileout "$jsonID" "LOW" "not offered"
               else
                    prln_svrty_critical " -- connection failed rather than downgrading to $latest_supported_string"
                    fileout "$jsonID" "CRITICAL" "connection failed rather than downgrading to $latest_supported_string"
               fi
               add_tls_offered tls1_3 no
               ;;
          2)   if [[ "$DETECTED_TLS_VERSION" == 0300 ]]; then
                    detected_version_string="SSLv3"
               elif [[ "$DETECTED_TLS_VERSION" == 03* ]]; then
                    detected_version_string="TLSv1.$((0x$DETECTED_TLS_VERSION-0x0301))"
               fi
               if [[ "$DETECTED_TLS_VERSION" == "$latest_supported" ]]; then
                    outln "not offered and downgraded to a weaker protocol"
                    fileout "$jsonID" "INFO" "not offered + downgraded to weaker protocol"
               elif [[ "$DETECTED_TLS_VERSION" == 03* ]] && [[ 0x$DETECTED_TLS_VERSION -lt 0x$latest_supported ]]; then
                    out "not offered"
                    prln_svrty_critical " -- server supports $latest_supported_string, but downgraded to $detected_version_string"
                    fileout "$jsonID" "CRITICAL" "not offered, and downgraded to $detected_version_string rather than $latest_supported_string"
               elif [[ "$DETECTED_TLS_VERSION" == 03* ]] && [[ 0x$DETECTED_TLS_VERSION -gt 0x0304 ]]; then
                    out "not offered"
                    prln_svrty_critical " -- server responded with higher version number ($detected_version_string) than requested by client"
                    fileout "$jsonID" "CRITICAL" "not offered, server responded with higher version number ($detected_version_string) than requested by client"
               else
                    out "not offered"
                    prln_svrty_critical " -- server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2}"
                    fileout "$jsonID" "CRITICAL" "server responded with version number ${DETECTED_TLS_VERSION:0:2}.${DETECTED_TLS_VERSION:2:2}"
               fi
               add_tls_offered tls1_3 no
               ;;
          3)   out "not offered  "
               fileout "$jsonID" "INFO" "not offered"
               add_tls_offered tls1_3 no
               pr_warning "TLS downgraded to STARTTLS plaintext"; outln
               fileout "$jsonID" "WARN" "TLS downgraded to STARTTLS plaintext"
               ;;
          4)   out "likely not offered, "
               fileout "$jsonID" "INFO" "not offered"
               add_tls_offered tls1_3 no
               pr_warning "received 4xx/5xx after STARTTLS handshake"; outln "$debug_recomm"
               fileout "$jsonID" "WARN" "received 4xx/5xx after STARTTLS handshake${debug_recomm}"
               ;;
          5)   outln "$supported_no_ciph1"             # protocol detected but no cipher --> comes from run_prototest_openssl
               fileout "$jsonID" "INFO" "$supported_no_ciph1"
               add_tls_offered tls1_3 yes
               ;;
          7)   if "$using_sockets" ; then
                    # can only happen in debug mode
                    prln_warning "strange reply, maybe a client side problem with TLS 1.3"; outln "$debug_recomm"
               else
                    prln_local_problem "$OPENSSL doesn't support \"s_client -tls1_3\""
                    fileout "$jsonID" "WARN" "not tested due to lack of local support"
               fi
               ((ret++))
               ;;
          *)   pr_fixme "unexpected value around line $((LINENO))"; outln "$debug_recomm"
               ((ret++))
               ;;
     esac

     debugme echo "PROTOS_OFFERED: $PROTOS_OFFERED"
     if [[ ! "$PROTOS_OFFERED" =~ yes ]]; then
          outln
          ignore_no_or_lame "You should not proceed as no protocol was detected. If you still really really want to, say \"YES\"" "YES"
          [[ $? -ne 0 ]] && exit $ERR_CLUELESS
     fi

     return $ret
}


# list ciphers (and makes sure you have them locally configured)
# arg[1]: non-TLSv1.3 cipher list (or anything else)
# arg[2]: TLSv1.3 cipher list
# arg[3]: protocol (e.g., -ssl2)
#
listciphers() {
     local -i ret
     local debugname=""
     local tls13_ciphers="$TLS13_OSSL_CIPHERS"

     [[ "$2" != "ALL" ]] && tls13_ciphers="$2"
     if "$HAS_CIPHERSUITES"; then
          $OPENSSL ciphers $OSSL_CIPHERS_S $3 -ciphersuites "$tls13_ciphers" "$1" &>$TMPFILE
     elif [[ -n "$tls13_ciphers" ]]; then
          $OPENSSL ciphers $OSSL_CIPHERS_S $3 "$tls13_ciphers:$1" &>$TMPFILE
     else
          $OPENSSL ciphers $OSSL_CIPHERS_S $3 "$1" &>$TMPFILE
     fi
     ret=$?
     debugme cat $TMPFILE
     debugname="$(sed -e s'/\!/not/g' -e 's/\:/_/g' <<< "$1")"
     tmpfile_handle ${FUNCNAME[0]}.${debugname}.txt
     return $ret
}


# argv[1]: non-TLSv1.3 cipher list to test in OpenSSL syntax
# argv[2]: TLSv1.3 cipher list to test in OpenSSL syntax
# argv[3]: string on console / HTML or "finding"
# argv[4]: rating whether ok to offer
# argv[5]: string to be appended for fileout
# argv[6]: non-SSLv2 cipher list to test (hexcodes), if using sockets
# argv[7]: SSLv2 cipher list to test (hexcodes), if using sockets
# argv[8]: true if using sockets, false if not
# argv[9]: CVE
# argv[10]: CWE
#
sub_cipherlists() {
     local -i i len sclient_success=1
     local cipherlist sslv2_cipherlist detected_ssl2_ciphers
     local singlespaces
     local proto=""
     local -i ret=0
     local jsonID="cipherlist"
     local using_sockets="${8}"
     local cve="${9}"
     local cwe="${10}"

     pr_bold "$3    "
     [[ "$OPTIMAL_PROTO" == -ssl2 ]] && proto="$OPTIMAL_PROTO"
     jsonID="${jsonID}_$5"

     if "$using_sockets" || listciphers "$1" "$2" $proto; then
          if ! "$using_sockets" || ( "$FAST" && listciphers "$1" "$2" -tls1 ); then
               for proto in -no_ssl2 -tls1_2 -tls1_1 -tls1 -ssl3; do
                    if [[ "$proto" == -tls1_2 ]]; then
                         # If $OPENSSL doesn't support TLSv1.3 or if no TLSv1.3
                         # ciphers are being tested, then a TLSv1.2 ClientHello
                         # was tested in the first iteration.
                         ! "$HAS_TLS13" && continue
                         [[ -z "$2" ]] && continue
                    fi
                    ! "$HAS_SSL3" && [[ "$proto" == -ssl3 ]] && continue
                    if [[ "$proto" != -no_ssl2 ]]; then
                         "$FAST" && continue
                         [[ $(has_server_protocol "${proto:1}") -eq 1 ]] && continue
                    fi
                    $OPENSSL s_client $(s_client_options "-cipher "$1" -ciphersuites "\'$2\'" $BUGS $STARTTLS -connect $NODEIP:$PORT $PROXY $SNI $proto") 2>$ERRFILE >$TMPFILE </dev/null
                    sclient_connect_successful $? $TMPFILE
                    sclient_success=$?
                    debugme cat $ERRFILE
                    [[ $sclient_success -eq 0 ]] && break
               done
          else
               for proto in 04 03 02 01 00; do
                    # If $cipherlist doesn't contain any TLSv1.3 ciphers, then there is
                    # no reason to try a TLSv1.3 ClientHello.
                    [[ "$proto" == 04 ]] && [[ ! "$6" =~ 13,0 ]] && continue
                    [[ $(has_server_protocol "$proto") -eq 1 ]] && continue
                    cipherlist="$(strip_inconsistent_ciphers "$proto" ", $6")"
                    cipherlist="${cipherlist:2}"
                    if [[ -n "$cipherlist" ]] && [[ "$cipherlist" != 00,ff ]]; then
                         tls_sockets "$proto" "$cipherlist"
                         sclient_success=$?
                         [[ $sclient_success -eq 2 ]] && sclient_success=0
                         [[ $sclient_success -eq 0 ]] && break
                    fi
               done
          fi
          if [[ $sclient_success -ne 0 ]] && [[ 1 -ne $(has_server_protocol ssl2) ]]; then
               if ( [[ -z "$7" ]] || "$FAST" ) && "$HAS_SSL2" && listciphers "$1" "" -ssl2; then
                    $OPENSSL s_client -cipher "$1" $BUGS $STARTTLS -connect $NODEIP:$PORT $PROXY -ssl2 2>$ERRFILE >$TMPFILE </dev/null
                    sclient_connect_successful $? $TMPFILE
                    sclient_success=$?
                    debugme cat $ERRFILE
               elif [[ -n "$7" ]]; then
                    sslv2_sockets "$7" "true"
                    if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
                         sslv2_cipherlist="$(strip_spaces "${6//,/}")"
                         len=${#sslv2_cipherlist}
                         detected_ssl2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
                         for (( i=0; i<len; i=i+6 )); do
                              [[ "$detected_ssl2_ciphers" =~ "x${sslv2_cipherlist:i:6}" ]] && sclient_success=0 && break
                         done
                    fi
               fi
          fi
          if [[ $sclient_success -ne 0 ]] && $BAD_SERVER_HELLO_CIPHER; then
               # If server failed with a known error, raise it to the user.
               if [[ $STARTTLS_PROTOCOL == mysql ]]; then
                    pr_warning "SERVER_ERROR: test inconclusive due to MySQL Community Edition (yaSSL) bug."
                    fileout "$jsonID" "WARN" "SERVER_ERROR, test inconclusive due to MySQL Community Edition (yaSSL) bug." "$cve" "$cwe"
               else
                    pr_warning "SERVER_ERROR: test inconclusive."
                    fileout "$jsonID" "WARN" "SERVER_ERROR, test inconclusive." "$cve" "$cwe"
               fi
               ((ret++))
          else
               # Otherwise the error means the server doesn't support that cipher list.
               case $4 in
                    2)  if [[ $sclient_success -eq 0 ]]; then
                              # Strong is excellent to offer
                              pr_svrty_best "offered (OK)"
                              fileout "$jsonID" "OK" "offered" "$cve" "$cwe"
                         else
                              pr_svrty_medium "not offered"
                              fileout "$jsonID" "MEDIUM" "not offered" "$cve" "$cwe"
                         fi
                         ;;
                    1)  if [[ $sclient_success -eq 0 ]]; then
                              # High is good to offer
                              pr_svrty_good "offered (OK)"
                              fileout "$jsonID" "OK" "offered" "$cve" "$cwe"
                         else
                              # FIXME: we penalize the absence of high but don't know the result of strong encryption yet (next)
                              pr_svrty_medium "not offered"
                              fileout "$jsonID" "MEDIUM" "not offered" "$cve" "$cwe"
                         fi
                         ;;
                    0)   if [[ $sclient_success -eq 0 ]]; then
                              # medium is not that bad
                              pr_svrty_low "offered"
                              fileout "$jsonID" "LOW" "offered" "$cve" "$cwe"
                         else
                              out "not offered"
                              fileout "$jsonID" "INFO" "not offered" "$cve" "$cwe"
                         fi
                         ;;
                    -1)  if [[ $sclient_success -eq 0 ]]; then
                              # bad but there is worse
                              pr_svrty_high "offered (NOT ok)"
                              fileout "$jsonID" "HIGH" "offered" "$cve" "$cwe"
                         else
                              # need a check for -eq 1 here
                              pr_svrty_good "not offered (OK)"
                              fileout "$jsonID" "OK" "not offered" "$cve" "$cwe"
                         fi
                         ;;
                    -2)  if [[ $sclient_success -eq 0 ]]; then
                              # the ugly ones
                              pr_svrty_critical "offered (NOT ok)"
                              fileout "$jsonID" "CRITICAL" "offered" "$cve" "$cwe"
                         else
                              pr_svrty_best "not offered (OK)"
                              fileout "$jsonID" "OK" "not offered" "$cve" "$cwe"
                         fi
                         ;;
                    *) # we shouldn't reach this
                         pr_warning "?: $4 (please report this)"
                         fileout "$jsonID" "WARN" "return condition $4 unclear" "$cve" "$cwe"
                         ((ret++))
                         ;;
               esac
          fi
          tmpfile_handle ${FUNCNAME[0]}.${5}.txt
          [[ $DEBUG -ge 1 ]] && tm_out " -- $1"
          outln
     else
          singlespaces=$(sed -e 's/ \+/ /g' -e 's/^ //' -e 's/ $//g' -e 's/  //g' <<< "$3")
          if [[ "$OPTIMAL_PROTO" == -ssl2 ]]; then
               prln_local_problem "No $singlespaces for SSLv2 configured in $OPENSSL"
          else
               prln_local_problem "No $singlespaces configured in $OPENSSL"
          fi
          fileout "$jsonID" "WARN" "Cipher $3 ($1) not supported by local OpenSSL ($OPENSSL)"
     fi
     return $ret
}

#TODO: work with fixed lists here --> atm ok, as sockets are preferred. If there would be a single function for testing: yes.
run_cipherlists() {
     local hexc hexcode strength
     local -i i
     local -i ret=0
     local ossl_null_ciphers null_ciphers sslv2_null_ciphers
     local ossl_anon_ciphers anon_ciphers sslv2_anon_ciphers
     local ossl_exp_ciphers exp_ciphers sslv2_exp_ciphers
     local ossl_low_ciphers low_ciphers sslv2_low_ciphers
     local ossl_tdes_ciphers tdes_ciphers sslv2_tdes_cipher
     local ossl_average_ciphers average_ciphers
     local strong_ciphers
     local cwe="CWE-327"
     local cwe2="CWE-310"
     local cve=""
     local using_sockets=true

     outln
     pr_headlineln " Testing cipher categories "
     outln
     "$SSL_NATIVE" && using_sockets=false

     # conversion 2 byte ciphers via:  echo "$@" | sed -e 's/[[:xdigit:]]\{2\},/0x&/g'  -e 's/, /\n/g' | while read ci; do grep -wi $ci etc/cipher-mapping.txt; done

     ossl_null_ciphers='NULL:eNULL'
     null_ciphers="c0,10, c0,06, c0,15, c0,0b, c0,01, c0,3b, c0,3a, c0,39, 00,b9, 00,b8, 00,b5, 00,b4, 00,2e, 00,2d, 00,b1, 00,b0, 00,2c, 00,3b, 00,02, 00,01, 00,82, 00,83, ff,87, 00,ff"
     sslv2_null_ciphers="FF,80,10, 00,00,00"

     ossl_anon_ciphers='aNULL:ADH'
     anon_ciphers="c0,19, 00,a7, 00,6d, 00,3a, 00,c5, 00,89, c0,47, c0,5b, c0,85, c0,18, 00,a6, 00,6c, 00,34, 00,bf, 00,9b, 00,46, c0,46, c0,5a, c0,84, c0,16, 00,18, c0,17, 00,1b, 00,1a, 00,19, 00,17, c0,15, 00,ff"
     sslv2_anon_ciphers="FF,80,10"

     ossl_exp_ciphers='EXPORT:!ADH:!NULL'
     # grep -i EXP etc/cipher-mapping.txt
     exp_ciphers="00,63, 00,62, 00,61, 00,65, 00,64, 00,60, 00,14, 00,11, 00,19, 00,08, 00,06, 00,27, 00,26, 00,2a, 00,29, 00,0b, 00,0e, 00,17, 00,03, 00,28, 00,2b, 00,ff"
     sslv2_exp_ciphers="04,00,80, 02,00,80, 00,00,00"

     ossl_low_ciphers='LOW:DES:RC2:RC4:!ADH:!EXP:!NULL:!eNULL'
     # egrep -w '64|56|RC2|RC4' etc/cipher-mapping.txt | egrep -v 'Au=None|export'
     low_ciphers="00,04, 00,05, 00,09, 00,0C, 00,0F, 00,12, 00,15, 00,1E, 00,20, 00,22, 00,24, 00,66, 00,8A, 00,8E, 00,92, C0,02, C0,07, C0,0C, C0,11, C0,33, FE,FE, FF,E1, 00,FF"
     sslv2_low_ciphers="01,00,80, 03,00,80, 06,00,40, 06,01,40, 08,00,80, FF,80,00"

     ossl_tdes_ciphers='3DES:IDEA:!aNULL:!ADH'
     # egrep -w '3DES|IDEA' etc/cipher-mapping.txt | grep -v "Au=None"
     tdes_ciphers="00,07, 00,0A, 00,0D, 00,10, 00,13, 00,16, 00,1F, 00,21, 00,23, 00,25, 00,8B, 00,8F, 00,93, C0,03, C0,08, C0,0D, C0,12, C0,1A, C0,1B, C0,1C, C0,34, FE,FF, FF,E0, 00,FF"
     sslv2_tdes_ciphers="05,00,80, 07,00,c0, 07,01,c0"

     ossl_average_ciphers='HIGH:MEDIUM:AES:CAMELLIA:ARIA:!IDEA:!CHACHA20:!3DES:!RC2:!RC4:!AESCCM8:!AESCCM:!AESGCM:!ARIAGCM:!aNULL'
     # egrep -w "256|128" etc/cipher-mapping.txt | egrep -v "Au=None|AEAD|RC2|RC4|IDEA"
     average_ciphers="00,2F, 00,30, 00,31, 00,32, 00,33, 00,35, 00,36, 00,37, 00,38, 00,39, 00,3C, 00,3D, 00,3E, 00,3F, 00,40, 00,41, 00,42, 00,43, 00,44, 00,45, 00,67, 00,68, 00,69, 00,6A, 00,6B, 00,84, 00,85, 00,86, 00,87, 00,88, 00,8C, 00,8D, 00,90, 00,91, 00,94, 00,95, 00,96, 00,97, 00,98, 00,99, 00,9A, 00,AE, 00,AF, 00,B2, 00,B3, 00,B6, 00,B7, 00,BA, 00,BB, 00,BC, 00,BD, 00,BE, 00,C0, 00,C1, 00,C2, 00,C3, 00,C4, C0,04, C0,05, C0,09, C0,0A, C0,0E, C0,0F, C0,13, C0,14, C0,1D, C0,1E, C0,1F, C0,20, C0,21, C0,22, C0,23, C0,24, C0,25, C0,26, C0,27, C0,28, C0,29, C0,2A, C0,35, C0,36, C0,37, C0,38, C0,3C, C0,3D, C0,3E, C0,3F, C0,40, C0,41, C0,42, C0,43, C0,44, C0,45, C0,48, C0,49, C0,4A, C0,4B, C0,4C, C0,4D, C0,4E, C0,4F, C0,64, C0,65, C0,66, C0,67, C0,68, C0,69, C0,70, C0,71, C0,72, C0,73, C0,74, C0,75, C0,76, C0,77, C0,78, C0,79, C0,94, C0,95, C0,96, C0,97, C0,98, C0,99, C0,9A, C0,9B"
     # Workaround: If we use sockets and in order not to hit 132+1 ciphers we omit the GOST ciphers if SERVER_SIZE_LIMIT_BUG is true.
     # This won't be supported by Cisco ACE anyway. Catch is, if SERVER_SIZE_LIMIT_BUG was not tested for before (only this function is being called)
     "$SERVER_SIZE_LIMIT_BUG" || average_ciphers="${average_ciphers}, 00,80, 00,81, FF,00, FF,01, FF,02, FF,03, FF,85"
     average_ciphers="${average_ciphers}, 00,FF"

     # Here's the strongest discrepancy between sockets and OpenSSL
     ossl_strong_ciphers='AESGCM:CHACHA20:AESGCM:CamelliaGCM:AESCCM:ARIAGCM'
     # grep AEAD etc/cipher-mapping.txt | grep -v Au=None
     strong_ciphers="00,9C, 00,9D, 00,9E, 00,9F, 00,A0, 00,A1, 00,A2, 00,A3, 00,A4, 00,A5, 00,A8, 00,A9, 00,AA, 00,AB, 00,AC, 00,AD, 13,01, 13,02, 13,03, 13,04, 13,05, 16,B7, 16,B8, 16,B9, 16,BA, C0,2B, C0,2C, C0,2D, C0,2E, C0,2F, C0,30, C0,31, C0,32, C0,50, C0,51, C0,52, C0,53, C0,54, C0,55, C0,56, C0,57, C0,58, C0,59, C0,5C, C0,5D, C0,5E, C0,5F, C0,60, C0,61, C0,62, C0,63, C0,6A, C0,6B, C0,6C, C0,6D, C0,6E, C0,6F, C0,7A, C0,7B, C0,7C, C0,7D, C0,7E, C0,7F, C0,80, C0,81, C0,82, C0,83, C0,86, C0,87, C0,88, C0,89, C0,8A, C0,8B, C0,8C, C0,8D, C0,8E, C0,8F, C0,90, C0,91, C0,92, C0,93, C0,9C, C0,9D, C0,9E, C0,9F, C0,A0, C0,A1, C0,A2, C0,A3, C0,A4, C0,A5, C0,A6, C0,A7, C0,A8, C0,A9, C0,AA, C0,AB, C0,AC, C0,AD, C0,AE, C0,AF, CC,13, CC,14, CC,15, CC,A8, CC,A9, CC,AA, CC,AB, CC,AC, CC,AD, CC,AE, 00,FF"

     # argv[1]: non-TLSv1.3 cipher list to test in OpenSSL syntax
     # argv[2]: TLSv1.3 cipher list to test in OpenSSL syntax
     # argv[3]: string on console / HTML or "finding"
     # argv[4]: rating whether ok to offer
     # argv[5]: string to be appended for fileout
     # argv[6]: non-SSLv2 cipher list to test (hexcodes), if using sockets
     # argv[7]: SSLv2 cipher list to test (hexcodes), if using sockets
     # argv[8]: true if using sockets, false if not
     # argv[9]: CVE
     # argv[10]: CWE

     sub_cipherlists "$ossl_null_ciphers"      "" " NULL ciphers (no encryption)              "    -2 "NULL"      "$null_ciphers"    "$sslv2_null_ciphers"   "$using_sockets" "$cve" "$cwe"
     ret=$?
     sub_cipherlists "$ossl_anon_ciphers"      "" " Anonymous NULL Ciphers (no authentication)"    -2 "aNULL"     "$anon_ciphers"    "$sslv2_anon_ciphers"   "$using_sockets" "$cve" "$cwe"
     ret=$((ret + $?))
     sub_cipherlists "$ossl_exp_ciphers"       "" " Export ciphers (w/o ADH+NULL)             "    -2 "EXPORT"    "$exp_ciphers"     "$sslv2_exp_ciphers"    "$using_sockets" "$cve" "$cwe"
     ret=$((ret + $?))
     sub_cipherlists "$ossl_low_ciphers"       "" " LOW: 64 Bit + DES, RC[2,4] (w/o export)   "    -2 "LOW"       "$low_ciphers"     "$sslv2_low_ciphers"    "$using_sockets" "$cve" "$cwe"
     ret=$((ret + $?))
     sub_cipherlists "$ossl_tdes_ciphers"      "" " Triple DES Ciphers / IDEA                 "    -1 "3DES_IDEA" "$tdes_ciphers"    "$sslv2_tdes_ciphers"   "$using_sockets" "$cve" "$cwe2"
     ret=$((ret + $?))
     sub_cipherlists "$ossl_average_ciphers"   "" " Obsolete: SEED + 128+256 Bit CBC cipher   "     0 "AVERAGE"   "$average_ciphers"  ""                     "$using_sockets" "$cve" "$cwe2"
     ret=$((ret + $?))
     sub_cipherlists "$ossl_strong_ciphers" 'ALL' " Strong encryption (AEAD ciphers)          "     2 "STRONG"    "$strong_ciphers"   ""                     "$using_sockets" ""      ""
     ret=$((ret + $?))

     outln
     return $ret
}

# The return value is an indicator of the quality of the DH key length in $1:
#   1 = pr_svrty_critical, 2 = pr_svrty_high, 3 = pr_svrty_medium, 4 = pr_svrty_low
#   5 = neither good nor bad, 6 = pr_svrty_good, 7 = pr_svrty_best
pr_dh_quality() {
     local bits="$1"
     local string="$2"

     if [[ "$bits" -le 600 ]]; then
          pr_svrty_critical "$string"
          return 1
     elif [[ "$bits" -le 800 ]]; then
          pr_svrty_high "$string"
          return 2
     elif [[ "$bits" -le 1280 ]]; then
          pr_svrty_medium "$string"
          return 3
     elif [[ "$bits" -ge 2048 ]]; then
          pr_svrty_good "$string"
          return 6
     else
          out "$string"
          return 5
     fi
}

# prints out dh group=prime and in round brackets DH bits and labels it accordingly
# arg1: name of dh group, arg2=bit length
pr_dh() {
     local -i quality=0

     pr_italic "$1"
     out " ("
     pr_dh_quality "$2" "$2 bits"
     quality=$?
     out ")"
     return $quality
}

pr_ecdh_quality() {
     local bits="$1"
     local string="$2"

     if [[ "$bits" -le 80 ]]; then      # has that ever existed?
          pr_svrty_critical "$string"
     elif [[ "$bits" -le 108 ]]; then   # has that ever existed?
          pr_svrty_high "$string"
     elif [[ "$bits" -le 163 ]]; then
          pr_svrty_medium "$string"
     elif [[ "$bits" -le 193 ]]; then   # hmm, according to https://wiki.openssl.org/index.php/Elliptic_Curve_Cryptography it should ok
          pr_svrty_low "$string"        # but openssl removed it https://github.com/drwetter/testssl.sh/issues/299#issuecomment-220905416
     elif [[ "$bits" -le 224 ]]; then
          out "$string"
     elif [[ "$bits" -gt 224 ]]; then
          pr_svrty_good "$string"
     else
          out "$string"
     fi
}

pr_ecdh_curve_quality() {
     curve="$1"
     local -i bits=0

     case "$curve" in
          "sect163k1") bits=163  ;;
          "sect163r1") bits=162  ;;
          "sect163r2") bits=163  ;;
          "sect193r1") bits=193  ;;
          "sect193r2") bits=193  ;;
          "sect233k1") bits=232  ;;
          "sect233r1") bits=233  ;;
          "sect239k1") bits=238  ;;
          "sect283k1") bits=281  ;;
          "sect283r1") bits=282  ;;
          "sect409k1") bits=407 ;;
          "sect409r1") bits=409  ;;
          "sect571k1") bits=570  ;;
          "sect571r1") bits=570  ;;
          "secp160k1") bits=161  ;;
          "secp160r1") bits=161  ;;
          "secp160r2") bits=161  ;;
          "secp192k1") bits=192  ;;
          "prime192v1") bits=192  ;;
          "secp224k1") bits=225  ;;
          "secp224r1") bits=224  ;;
          "secp256k1") bits=256  ;;
          "prime256v1") bits=256  ;;
          "secp384r1") bits=384  ;;
          "secp521r1") bits=521  ;;
          "brainpoolP256r1") bits=256  ;;
          "brainpoolP384r1") bits=384  ;;
          "brainpoolP512r1") bits=512  ;;
          "X25519") bits=253  ;;
          "X448") bits=448  ;;
     esac
     pr_ecdh_quality "$bits" "$curve"
}

# Print $2 based on the quality of the cipher in $1. If $2 is empty, print $1.
# The return value is an indicator of the quality of the cipher in $1:
#   0 = $1 is empty
#   1 = pr_svrty_critical, 2 = pr_svrty_high, 3 = pr_svrty_medium, 4 = pr_svrty_low
#   5 = neither good nor bad, 6 = pr_svrty_good, 7 = pr_svrty_best
#
# Please note this section isn't particular spot on. It needs to be reconsidered/redone
pr_cipher_quality() {
     local cipher="$1"
     local text="$2"

     [[ -z "$1" ]] && return 0
     [[ -z "$text" ]] && text="$cipher"

     if [[ "$cipher" != TLS_* ]] && [[ "$cipher" != SSL_* ]]; then
          # This must be the OpenSSL name for a cipher
          if [[ $TLS_NR_CIPHERS -eq 0 ]]; then
               # We have an OpenSSL name and can't convert it to the RFC name
               case "$cipher" in
                    *NULL*|*EXP*|ADH*)
                         pr_svrty_critical "$text"
                         return 1
                         ;;
                    *RC4*|*RC2*)
                         pr_svrty_high "$text"
                         return 2
                         ;;
                    AES256-GCM-SHA384|AES128-GCM-SHA256|AES256-CCM|AES128-CCM|ARIA256-GCM-SHA384|ARIA128-GCM-SHA256)
                         # RSA kx and e.g. GCM isn't certainly the best
                         pr_svrty_good "$text"
                         return 6
                         ;;
                    *GCM*|*CCM*|*CHACHA20*)
                         pr_svrty_best "$text"
                         return 7
                         ;; #best ones
                    ECDHE*AES*|DHE*AES*SHA*|*CAMELLIA*SHA)
                         pr_svrty_low "$text"
                         return 4
                         ;; # it's CBC. --> lucky13
                    *CBC*)
                         pr_svrty_medium "$text"
                         return 3
                         ;; # FIXME BEAST: We miss some CBC ciphers here, need to work w/ a list
                    *)
                         out "$text"
                         return 5
                         ;;
               esac
          fi
          cipher="$(openssl2rfc "$cipher")"
     fi

     case "$cipher" in
          *NULL*|*EXP*|*RC2*|*_DES_*|*_DES40_*|*anon*)
               pr_svrty_critical "$text"
               return 1
               ;;
          *RC4*|*RC2*)
               pr_svrty_high "$text"
               return 2
               ;;
          TLS_RSA_*)
               if [[ "$cipher" =~ CBC ]]; then
                    pr_svrty_low "$text"
                    return 4
               else
                    pr_svrty_good "$text"
                    # RSA kx and e.g. GCM isn't certainly the best
                    return 6
               fi
               ;;
          *GCM*|*CCM*|*CHACHA20*)
               pr_svrty_best "$text"
               return 7
               ;;
          *ECDHE*AES*CBC*|*DHE*AES*SHA*|*RSA*AES*SHA*|*CAMELLIA*SHA*)
               pr_svrty_low "$text"
               return 4
               ;;
          *CBC*)
               pr_svrty_medium "$text"
               return 3
               ;;
          *)
               out "$text"
               return 5
               ;;
     esac
}

# arg1: file with input for grepping the type of ephemeral DH key (DH ECDH)
read_dhtype_from_file() {
     local temp kx

     temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$1")        # extract line
     kx="Kx=${temp%%,*}"
     [[ "$kx" == "Kx=X25519" ]] && kx="Kx=ECDH"
     [[ "$kx" == "Kx=X448" ]] && kx="Kx=ECDH"
     tm_out "$kx"
     return 0
}

# arg1: certificate file
read_sigalg_from_file() {
     $OPENSSL x509 -noout -text -in "$1" 2>/dev/null | awk -F':' '/Signature Algorithm/ { print $2; exit; }'
}


# arg1: file with input for grepping the bit length for ECDH/DHE
# arg2: whether to print warning "old fart" or not (empty: no)
read_dhbits_from_file() {
     local bits what_dh temp curve=""
     local add=""
     local old_fart=" (your $OPENSSL cannot show DH bits)"

     temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$1")        # extract line
     what_dh="${temp%%,*}"
     bits="${temp##*, }"
     curve="${temp#*, }"
     if [[ "$curve" == "$bits" ]]; then
          curve=""
     else
          curve="${curve%%,*}"
     fi
     bits="${bits/bits/}"
     bits="${bits// /}"

     if [[ "$what_dh" == "X25519" ]] || [[ "$what_dh" == "X448" ]]; then
          curve="$what_dh"
          what_dh="ECDH"
     fi
     if [[ -z "$2" ]]; then
          if [[ -n "$curve" ]]; then
               debugme echo ">$HAS_DH_BITS|$what_dh($curve)|$bits<"
          else
               debugme echo ">$HAS_DH_BITS|$what_dh|$bits<"
          fi
     fi
     [[ -n "$what_dh" ]] && HAS_DH_BITS=true                            # FIX 190
     if [[ -z "$what_dh" ]] && ! "$HAS_DH_BITS"; then
          if [[ "$2" == "string" ]]; then
               tm_out "$old_fart"
          elif [[ -z "$2" ]]; then
               pr_warning "$old_fart"
          fi
          return 0
     fi
     if [[ "$2" == quiet ]]; then
          tm_out "$bits"
          return 0
     fi
     [[ -z "$2" ]] && [[ -n "$bits" ]] && out ", "
     if [[ $what_dh == DH ]] || [[ $what_dh == EDH ]]; then
          add="bit DH"
          [[ -n "$curve" ]] && add+=" ($curve)"
          if [[ "$2" == string ]]; then
               tm_out ", $bits $add"
          else
               pr_dh_quality "$bits" "$bits $add"
          fi
     # https://wiki.openssl.org/index.php/Elliptic_Curve_Cryptography, http://www.keylength.com/en/compare/
     elif [[ $what_dh == ECDH ]]; then
          add="bit ECDH"
          [[ -n "$curve" ]] && add+=" ($curve)"
          if [[ "$2" == string ]]; then
               tm_out ", $bits $add"
          else
               pr_ecdh_quality "$bits" "$bits $add"
          fi
     fi
     return 0
}


# arg1: ID or empty. If empty resumption by ticket will be tested, otherwise by ID
# return: 0: it has resumption, 1:nope, 2: nope (OpenSSL 1.1.1),  6: CLIENT_AUTH --> problem for resumption, 7: can't tell
#
# This is basically a short(?) version from Bulletproof SSL and TLS (p386). The version according to that would be e.g.
#     echo | $OPENSSL s_client -connect testssl.sh:443 -servername testssl.sh -no_ssl2            -reconnect 2>&1 | grep -E 'New|Reused'
#     echo | $OPENSSL s_client -connect testssl.sh:443 -servername testssl.sh -no_ssl2 -no_ticket -reconnect 2>&1 | grep -E 'New|Reused|Session-ID'
#
# FIXME: actually Ivan's version seems faster. Worth to check and since when -reconnect is a/v
#
sub_session_resumption() {
     local ret ret1 ret2
     local tmpfile=$(mktemp $TEMPDIR/session_resumption.$NODEIP.XXXXXX)
     local sess_data=$(mktemp $TEMPDIR/sub_session_data_resumption.$NODEIP.XXXXXX)
     local -a rw_line
     local not_new_reused=false
     local protocol="$1"

     if [[ "$2" == ID ]]; then
          local byID=true
          local addcmd="-no_ticket"
     else
          local byID=false
          local addcmd=""
          if ! "$TLS_TICKETS"; then
               return 1
          fi
     fi
     "$CLIENT_AUTH" && return 3
     if "$HAS_NO_SSL2"; then
          addcmd+=" -no_ssl2"
     else
          protocol=${protocol/\./_}
          protocol=${protocol/v/}
          protocol="-$(tolower $protocol)"
          # In some cases a server will not support session tickets, but will support session resumption
          # by ID. In such a case, it may be more likely to support session resumption with TLSv1.2 than
          # with TLSv1.3. So, if testing a server that does not support session tickets and that supports
          # both TLSv1.3 and TLSv1.2 for session resumption by ID, then use a TLSv1.2 ClientHello. (Note that
          # the line below assumes that if $protocol is -tls1_3, then the server either supports TLSv1.2 or
          # is TLSv1.3-only.
          ! "$TLS_TICKETS" && "$byID" && [[ $(has_server_protocol "tls1_2") -eq 0 ]] && protocol="-tls1_2" 
          addcmd+=" $protocol"
     fi

     $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI $addcmd -sess_out $sess_data") </dev/null &>/dev/null
     ret1=$?
     if [[ $ret1 -ne 0 ]]; then
          debugme echo -n "Couldn't connect #1  "
          return 7
     fi
     if "$byID" && [[ ! "$OSSL_NAME" =~ LibreSSL ]] && \
        ( [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.1* ]] || [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 3.0.0* ]] ) && \
        [[ ! -s "$sess_data" ]]; then
          # it seems OpenSSL indicates no Session ID resumption by just not generating output
          debugme echo -n "No session resumption byID (empty file)"
          ret=2
     else
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI $addcmd -sess_in $sess_data") </dev/null >$tmpfile 2>$ERRFILE
          ret2=$?
          if [[ $DEBUG -ge 2 ]]; then
               echo -n "$ret1, $ret2, "
               [[ -s "$sess_data" ]] && echo "not empty" || echo "empty"
          fi
          if [[ $ret2 -ne 0 ]]; then
               debugme echo -n "Couldn't connect #2  "
               return 7
          fi
          # "Reused" indicates session material was reused, "New": not
          if grep -aq "^Reused" "$tmpfile"; then
               new_sid=false
          elif grep -aq "^New" "$tmpfile"; then
               new_sid=true
          else
               debugme echo -n "Problem with 2nd ServerHello  "
               not_new_reused=true
          fi
          # Now get the line and compare the numbers "read" and "written" as a second criteria.
          # If the "read" number is bigger: a new session ID was probably used
          rw_line="$(awk '/^SSL handshake has read/ { print $5" "$(NF-1) }' "$tmpfile" )"
          rw_line=($rw_line)
          if [[ "${rw_line[0]}" -gt "${rw_line[1]}" ]]; then
               new_sid2=true
          else
               new_sid2=false
          fi
          debugme echo "${rw_line[0]}, ${rw_line[1]}"
 
          if "$new_sid2" && "$new_sid"; then
               debugme echo -n "No session resumption "
               ret=1
          elif ! "$new_sid2" && ! "$new_sid"; then
               debugme echo -n "Session resumption "
               ret=0
          else
               debugme echo -n "unclear status: $ret1, $ret2, $new_sid, $new_sid2  -- "
               ret=5
          fi
          if [[ $DEBUG -ge 2 ]]; then
               "$byID" && echo "byID" || echo "by ticket"
          fi
     fi
     "$byID" && \
          tmpfile_handle ${FUNCNAME[0]}.byID.log $tmpfile || \
          tmpfile_handle ${FUNCNAME[0]}.byticket.log $tmpfile
     return $ret
}

run_server_preference() {
     local cipher1="" cipher2="" tls13_cipher1="" tls13_cipher2="" default_proto=""
     local prev_cipher="" default_cipher=""
     local limitedsense="" supported_sslv2_ciphers
     local -a cipher proto
     local proto_ossl proto_txt proto_hex cipherlist i
     local -i ret=0 j sclient_success str_len
     local list_fwd="DHE-RSA-SEED-SHA:SEED-SHA:DES-CBC3-SHA:RC4-MD5:DES-CBC-SHA:RC4-SHA:AES128-SHA:AES128-SHA256:AES256-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-RSA-AES128-SHA:ECDH-RSA-AES256-SHA:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:DHE-DSS-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:AES256-SHA256:ECDHE-RSA-DES-CBC3-SHA:ECDHE-RSA-AES128-SHA256:AES256-GCM-SHA384:AES128-GCM-SHA256:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-SHA256:ADH-AES256-GCM-SHA384:AECDH-AES128-SHA:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-AES128-SHA"
     local list_reverse="ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-RC4-SHA:AECDH-AES128-SHA:ADH-AES256-GCM-SHA384:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-GCM-SHA256:AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-DES-CBC3-SHA:AES256-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-DSS-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDH-RSA-AES256-SHA:ECDH-RSA-AES128-SHA:ECDH-RSA-DES-CBC3-SHA:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-AES128-SHA:AES256-SHA:AES128-SHA256:AES128-SHA:RC4-SHA:DES-CBC-SHA:RC4-MD5:DES-CBC3-SHA:SEED-SHA:DHE-RSA-SEED-SHA"
     tls_list_fwd="c0,2c, c0,30, 00,9f, cc,a9, cc,a8, cc,aa, c0,2b, c0,2f, 00,9e, c0,24, c0,28, 00,6b, c0,23, c0,27, 00,67, c0,0a, 00,04, 00,05, 00,09, 00,0a, 00,9a, 00,96,
                   c0,14, 00,39, c0,09, c0,13, 00,33, 00,9d, 00,9c, 13,01, 13,02, 13,03, 13,04, 13,05, 00,3d, 00,3c, 00,35, 00,2f, 00,ff"
     tls_list_rev="00,2f, 00,35, 00,3c, 00,3d, 13,05, 13,04, 13,03, 13,02, 13,01, 00,9c, 00,9d, 00,33, c0,13, c0,09, 00,39, c0,14, 00,96, 00,9a, 00,0a, 00,09, 00,05, 00,04,
                   c0,0a, 00,67, c0,27, c0,23, 00,6b, c0,28, c0,24, 00,9e, c0,2f, c0,2b, cc,aa, cc,a8, cc,a9, 00,9f, c0,30, c0,2c, 00,ff"
     local has_cipher_order=false has_tls13_cipher_order=false
     local addcmd="" addcmd2=""
     local using_sockets=true
     local jsonID="cipher_order"
     local cwe="CWE-310"
     local cve=""

     "$SSL_NATIVE" && using_sockets=false

     outln
     pr_headlineln " Testing server preferences "

     outln
     pr_bold " Has server cipher order?     "

     if [[ "$OPTIMAL_PROTO" == -ssl2 ]]; then
          addcmd="$OPTIMAL_PROTO"
     else
          # the supplied openssl will send an SSLv2 ClientHello if $SNI is empty
          # and the -no_ssl2 isn't provided.
          addcmd="-no_ssl2 $SNI"
     fi

     # Determine negotiated protocol upfront
     sclient_success=1
     if "$using_sockets" && [[ $(has_server_protocol "tls1_3") -ne 1 ]]; then
          # Send similar list of cipher suites as OpenSSL 1.1.1 does
          tls_sockets "04" \
                      "c0,2c, c0,30, 00,9f, cc,a9, cc,a8, cc,aa, c0,2b, c0,2f, 00,9a, 00,96,
                       00,9e, c0,24, c0,28, 00,6b, c0,23, c0,27, 00,67, c0,0a,
                       c0,14, 00,39, c0,09, c0,13, 00,33, 00,9d, 00,9c, 13,02,
                       13,03, 13,01, 13,04, 13,05, 00,3d, 00,3c, 00,35, 00,2f, 00,ff" \
                      "ephemeralkey"
          sclient_success=$?
          if [[ $sclient_success -eq 0 ]]; then
               add_tls_offered tls1_3 yes
          elif [[ $sclient_success -eq 2 ]]; then
               sclient_success=0           # 2: downgraded
               case $DETECTED_TLS_VERSION in
                    0303) add_tls_offered tls1_2 yes ;;
                    0302) add_tls_offered tls1_1 yes ;;
                    0301) add_tls_offered tls1 yes ;;
                    0300) add_tls_offered ssl3 yes ;;
               esac
          fi
          if [[ $sclient_success -eq 0 ]] ; then
               cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
               cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" "$TEMPDIR/$NODEIP.parse_tls13_serverhello.txt"
               cipher0=$(get_cipher $TMPFILE)
          fi
     fi
     if [[ $sclient_success -ne 0 ]]; then
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $addcmd") </dev/null 2>>$ERRFILE >$TMPFILE
          if sclient_connect_successful $? $TMPFILE; then
               cipher0=$(get_cipher $TMPFILE)
               debugme tm_out "0 --> $cipher0\n"
          else
               # 2 second try with $OPTIMAL_PROTO especially for intolerant IIS6 servers:
               $OPENSSL s_client $(s_client_options "$STARTTLS $OPTIMAL_PROTO $BUGS -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
               if ! sclient_connect_successful $? $TMPFILE; then
                    pr_warning "Handshake error!"
                    ret=1
               fi
          fi
     fi
     default_proto=$(get_protocol $TMPFILE)
     [[ "$default_proto" == TLSv1.0 ]] && default_proto="TLSv1"
     # debugme tm_out " --> $default_proto\n"

     # Some servers don't have a TLS 1.3 cipher order, see #1163
     if [[ "$default_proto" == TLSv1.3 ]]; then
          tls_sockets "04" "13,05, 13,04, 13,03, 13,02, 13,01, 00,ff"
          [[ $sclient_success -ne 0 ]] && ret=1 && prln_fixme "something weird happened around line $((LINENO - 1))"
          cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
          tls13_cipher1=$(get_cipher $TMPFILE)
          debugme tm_out "TLS 1.3: --> $tls13_cipher1\n"
          tls_sockets "04" "13,01, 13,02, 13,03, 13,04, 13,05, 00,ff"
          [[ $sclient_success -ne 0 ]] && ret=1 && prln_fixme "something weird happened around line $((LINENO - 1))"
          cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
          tls13_cipher2=$(get_cipher $TMPFILE)
          debugme tm_out "TLS 1.3: --> $tls13_cipher2\n"

          [[ $tls13_cipher1 == $tls13_cipher2 ]] && has_tls13_cipher_order=true
     fi
     # Check whether the server has a cipher order for SSLv3 - TLSv1.2
     if [[ $(has_server_protocol "tls1_2") -ne 0 ]] && [[ $(has_server_protocol "tls1_1") -ne 0 ]] && \
        [[ $(has_server_protocol "tls1") -ne 0 ]] && [[ $(has_server_protocol "ssl3") -ne 0 ]]; then
          # Based on testing performed by determine_optimal_sockets_params(), it is believed that
          # this server does not offer SSLv3 - TLSv1.2.
          has_cipher_order="$has_tls13_cipher_order"
     elif [[ "$OPTIMAL_PROTO" != -ssl2 ]]; then
          if [[ -n "$STARTTLS_OPTIMAL_PROTO" ]]; then
               [[ ! "$STARTTLS_OPTIMAL_PROTO" =~ ssl ]] && addcmd2="$SNI"
               [[ "$STARTTLS_OPTIMAL_PROTO" != -tls1_3 ]] && addcmd2+=" $STARTTLS_OPTIMAL_PROTO"
          else
               addcmd2="-no_ssl2 $SNI"
          fi
          [[ $DEBUG -ge 4 ]] && echo -e "\n Forward: ${list_fwd}"
          $OPENSSL s_client $(s_client_options "$STARTTLS -cipher $list_fwd $BUGS -connect $NODEIP:$PORT $PROXY $addcmd2") </dev/null 2>$ERRFILE >$TMPFILE
          if ! sclient_connect_successful $? $TMPFILE; then
               list_fwd="$(actually_supported_ciphers $list_fwd '' '-tls1')"
               pr_warning "no matching cipher in this list found (pls report this): "
               outln "$list_fwd  . "
               fileout "$jsonID" "WARN" "Could not determine server cipher order, no matching cipher in list found (pls report this): $list_fwd"
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
               # we assume the problem is with testing here but it could be also the server side
          fi
          cipher1=$(get_cipher $TMPFILE)               # cipher1 from 1st serverhello
          debugme tm_out "1 --> $cipher1\n"

          # second client hello with reverse list
          [[ $DEBUG -ge 4 ]] && echo -e "\n Reverse: ${list_reverse}"
          $OPENSSL s_client $(s_client_options "$STARTTLS -cipher $list_reverse $BUGS -connect $NODEIP:$PORT $PROXY $addcmd2") </dev/null 2>>$ERRFILE >$TMPFILE
          # first handshake worked above so no error handling here
          cipher2=$(get_cipher $TMPFILE)               # cipher2 from 2nd serverhello
          debugme tm_out "2 --> $cipher2\n"

          [[ $cipher1 == $cipher2 ]] && has_cipher_order=true
     fi
     debugme echo "has_cipher_order: $has_cipher_order"
     debugme echo "has_tls13_cipher_order: $has_tls13_cipher_order"

     if "$TLS13_ONLY" && ! "$has_tls13_cipher_order"; then
          out "no (TLS 1.3 only)"
          limitedsense=" (limited sense as client will pick)"
          fileout "$jsonID" "INFO" "not a cipher order for TLS 1.3 configured"
     elif ! "$has_cipher_order" && ! "$has_tls13_cipher_order"; then
          # server used the different ends (ciphers) from the client hello
          pr_svrty_high "no (NOT ok)"
          limitedsense=" (limited sense as client will pick)"
          fileout "$jsonID" "HIGH" "NOT a cipher order configured"
     elif "$has_cipher_order" && ! "$has_tls13_cipher_order" && [[ "$default_proto" == TLSv1.3 ]]; then
          pr_svrty_good "yes (OK)"; out " -- only for < TLS 1.3"
          fileout "$jsonID" "OK" "server -- TLS 1.3 client determined"
     elif ! "$has_cipher_order" && "$has_tls13_cipher_order"; then
          pr_svrty_high "no (NOT ok)"; out " -- only for TLS 1.3"
          fileout "$jsonID" "HIGH" "server -- < TLS 1.3 client determined"
     else
          if "$has_tls13_cipher_order"; then
               if "$TLS13_ONLY"; then
                    out "yes (TLS 1.3 only)"
                    fileout "$jsonID" "INFO" "server (TLS 1.3)"
               else
                    pr_svrty_best "yes (OK)"
                    out " -- TLS 1.3 and below"
                    fileout "$jsonID" "OK" "server"
               fi
          else
               # we don't have TLS 1.3 at all
               pr_svrty_best "yes (OK)"
               fileout "$jsonID" "OK" "server"
          fi
     fi
     outln

     pr_bold " Negotiated protocol          "
     jsonID="protocol_negotiated"

     case "$default_proto" in
          *TLSv1.3)
               prln_svrty_best $default_proto
               fileout "$jsonID" "OK" "Default protocol TLS1.3"
               ;;
          *TLSv1.2)
               prln_svrty_best $default_proto
               fileout "$jsonID" "OK" "Default protocol TLS1.2"
               ;;
          *TLSv1.1)
               prln_svrty_good $default_proto
               fileout "$jsonID" "OK" "Default protocol TLS1.1"
               ;;
          *TLSv1)
               outln $default_proto
               fileout "$jsonID" "INFO" "Default protocol TLS1.0"
               ;;
          *SSLv2)
               prln_svrty_critical $default_proto
               fileout "$jsonID" "CRITICAL" "Default protocol SSLv2"
               ;;
          *SSLv3)
               prln_svrty_critical $default_proto
               fileout "$jsonID" "CRITICAL" "Default protocol SSLv3"
               ;;
          "")
               pr_warning "default proto empty"
               if [[ $OSSL_VER == 1.0.2* ]]; then
                    outln " (Hint: if IIS6 give OpenSSL 1.0.1 a try)"
                    fileout "$jsonID" "WARN" "Default protocol empty (Hint: if IIS6 give OpenSSL 1.0.1 a try)"
               else
                    outln
                    fileout "$jsonID" "WARN" "Default protocol empty"
               fi
               ret=1
               ;;
          *)
               pr_warning "FIXME line $LINENO: $default_proto"
               fileout "$jsonID" "WARN" "FIXME line $LINENO: $default_proto"
               ret=1
               ;;
     esac

     pr_bold " Negotiated cipher            "
     jsonID="cipher_negotiated"

     # restore file from above
     [[ "$default_proto" == TLSv1.3 ]] && cp "$TEMPDIR/$NODEIP.parse_tls13_serverhello.txt" $TMPFILE
     cipher1=$(get_cipher $TMPFILE)

     # Sanity check: Handshake with no ciphers and one with forward list didn't overlap
     if [[ "$cipher0" != $cipher1 ]]; then
          limitedsense=" (matching cipher in list missing)"
     fi

     if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && ( [[ "$cipher1" == TLS_* ]] || [[ "$cipher1" == SSL_* ]] ); then
          default_cipher="$(rfc2openssl "$cipher1")"
     elif [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]] && [[ "$cipher1" != TLS_* ]] && [[ "$cipher1" != SSL_* ]]; then
          default_cipher="$(openssl2rfc "$cipher1")"
     fi
     [[ -z "$default_cipher" ]] && default_cipher="$cipher1"
     pr_cipher_quality "$default_cipher"
     case $? in
          1)   fileout "$jsonID" "CRITICAL" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") $limitedsense"
               ;;
          2)   fileout "$jsonID" "HIGH" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") $limitedsense"
               ;;
          3)   fileout "$jsonID" "MEDIUM" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") $limitedsense"
               ;;
          6|7) fileout "$jsonID" "OK" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") $limitedsense"
               ;;   # best ones
          4)   fileout "$jsonID" "LOW" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") (cbc) $limitedsense"
               ;;  # it's CBC. --> lucky13
          0)   pr_warning "default cipher empty" ;
               if [[ $OSSL_VER == 1.0.2* ]]; then
                    out " (Hint: if IIS6 give OpenSSL 1.0.1 a try)"
                    fileout "$jsonID" "WARN" "Default cipher empty  (if IIS6 give OpenSSL 1.0.1 a try) $limitedsense"
               else
                    fileout "$jsonID" "WARN" "Default cipher empty $limitedsense"
               fi
               ret=1
               ;;
          *)   fileout "$jsonID" "INFO" "$default_cipher$(read_dhbits_from_file "$TMPFILE" "string") $limitedsense"
               ;;
     esac
     read_dhbits_from_file "$TMPFILE"

     if [[ "$cipher0" != $cipher1 ]]; then
          pr_warning " -- inconclusive test, matching cipher in list missing"
          outln ", better see below"
          #FIXME: This is ugly but the best we can do before rewrite this section
     else
          outln "$limitedsense"
     fi

     if "$has_cipher_order"; then
          "$FAST" && using_sockets=false
          [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

          pr_bold " Cipher order"
          while read proto_ossl proto_hex proto_txt; do
               [[ "$proto_ossl" == tls1_3 ]] && ! "$has_tls13_cipher_order" && continue
               cipher_pref_check "$proto_ossl" "$proto_hex" "$proto_txt" "$using_sockets"
          done <<< "$(tm_out " ssl3 00 SSLv3\n tls1 01 TLSv1\n tls1_1 02 TLSv1.1\n tls1_2 03 TLSv1.2\n tls1_3 04 TLSv1.3\n")"
          outln
          outln
     else
          pr_bold " Negotiated cipher per proto"; outln " $limitedsense"
          i=1
          for proto_ossl in ssl2 ssl3 tls1 tls1_1 tls1_2 tls1_3; do
               if [[ $proto_ossl == ssl2 ]] && ! "$HAS_SSL2"; then
                    if ! "$using_sockets" || [[ $TLS_NR_CIPHERS -eq 0 ]]; then
                         out "     (SSLv2: "; pr_local_problem "$OPENSSL doesn't support \"s_client -ssl2\""; outln ")";
                         continue
                    else
                         sslv2_sockets "" "true"
                         if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
                              # Just arbitrarily pick the first cipher in the cipher-mapping.txt list.
                              proto[i]="SSLv2"
                              supported_sslv2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
                              for (( j=0; j < TLS_NR_CIPHERS; j++ )); do
                                   if [[ "${TLS_CIPHER_SSLVERS[j]}" == "SSLv2" ]]; then
                                        cipher1="${TLS_CIPHER_HEXCODE[j]}"
                                        cipher1="$(tolower "x${cipher1:2:2}${cipher1:7:2}${cipher1:12:2}")"
                                        if [[ "$supported_sslv2_ciphers" =~ $cipher1 ]]; then
                                             if ( [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ "${TLS_CIPHER_OSSL_NAME[j]}" != "-" ]] ) || [[ "${TLS_CIPHER_RFC_NAME[j]}" == "-" ]]; then
                                                  cipher[i]="${TLS_CIPHER_OSSL_NAME[j]}"
                                             else
                                                  cipher[i]="${TLS_CIPHER_RFC_NAME[j]}"
                                             fi
                                             break
                                        fi
                                   fi
                              done
                              [[ $DEBUG -ge 2 ]] && tmln_out "Default cipher for ${proto[i]}: ${cipher[i]}"
                         else
                              proto[i]=""
                              cipher[i]=""
                         fi
                    fi
               elif ( [[ $proto_ossl == ssl3 ]] && ! "$HAS_SSL3" ) || ( [[ $proto_ossl == tls1_3 ]] && ! "$HAS_TLS13" ); then
                    if [[ $proto_ossl == ssl3 ]]; then
                         proto_txt="SSLv3" ; proto_hex="00" ; cipherlist="$TLS_CIPHER"
                    else
                         proto_txt="TLSv1.3" ; proto_hex="04" ; cipherlist="$TLS13_CIPHER"
                    fi
                    if ! "$using_sockets"; then
                         out "     ($proto_txt: "; pr_local_problem "$OPENSSL doesn't support \"s_client -$proto_ossl\"" ; outln ")";
                         continue
                    else
                         tls_sockets "$proto_hex" "$cipherlist"
                         if [[ $? -eq 0 ]]; then
                              proto[i]="$proto_txt"
                              cipher1=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                              cipher[i]="$cipher1"
                              if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ $TLS_NR_CIPHERS -ne 0 ]]; then
                                   cipher[i]="$(rfc2openssl "$cipher1")"
                                   [[ -z "${cipher[i]}" ]] && cipher[i]="$cipher1"
                              fi
                              [[ $DEBUG -ge 2 ]] && tmln_out "Default cipher for ${proto[i]}: ${cipher[i]}"
                         else
                              proto[i]=""
                              cipher[i]=""
                         fi
                    fi
               else
                    $OPENSSL s_client $(s_client_options "$STARTTLS -"$proto_ossl" $BUGS -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
                    if sclient_connect_successful $? $TMPFILE; then
                         proto[i]=$(get_protocol $TMPFILE)
                         cipher[i]=$(get_cipher $TMPFILE)
                         [[ ${cipher[i]} == "0000" ]] && cipher[i]=""                     # Hack!
                         if [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]] && [[ -n "${cipher[i]}" ]]; then
                              cipher[i]="$(openssl2rfc "${cipher[i]}")"
                              [[ -z "${cipher[i]}" ]] && cipher[i]=$(get_cipher $TMPFILE)
                         fi
                         [[ $DEBUG -ge 2 ]] && tmln_out "Default cipher for ${proto[i]}: ${cipher[i]}"
                    else
                         proto[i]=""
                         cipher[i]=""
                    fi
               fi
               [[ -n "${cipher[i]}" ]] && add_tls_offered "$proto_ossl" yes
               i=$((i + 1))
          done

          for i in 1 2 3 4 5 6; do
               if [[ -n "${cipher[i]}" ]]; then                                      # cipher not empty
                     if [[ -z "$prev_cipher" ]] || [[ "$prev_cipher" != "${cipher[i]}" ]]; then
                         [[ -n "$prev_cipher" ]] && outln
                         str_len=${#cipher[i]}
                         out "     "
                         if [[ "$COLOR" -le 2 ]]; then
                              out "${cipher[i]}"
                         else
                              pr_cipher_quality "${cipher[i]}"
                         fi
                         out ":"
                         if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]]; then
                              for (( 1; str_len < 30; str_len++ )); do
                                   out " "
                              done
                         else
                              for (( 1; str_len < 51; str_len++ )); do
                                   out " "
                              done
                         fi
                    else
                         out ", "           # same cipher --> only print out protocol behind it
                    fi
                    out "${proto[i]}"
                    prev_cipher="${cipher[i]}"
               fi
               fileout "cipher_order_${proto[i]}" "INFO" "${cipher[i]} at ${proto[i]} $limitedsense"
          done
          outln "\n No further cipher order check has been done as order is determined by the client"
          outln
     fi
     return $ret
}

check_tls12_pref() {
     local batchremoved="-CAMELLIA:-IDEA:-KRB5:-PSK:-SRP:-aNULL:-eNULL"
     local batchremoved_success=false
     local tested_cipher="" cipher ciphers_to_test
     local order=""
     local -i nr_ciphers_found_r1=0 nr_ciphers_found_r2=0

     while true; do
          $OPENSSL s_client $(s_client_options "$STARTTLS -tls1_2 $BUGS -cipher "ALL$tested_cipher:$batchremoved" -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
          if sclient_connect_successful $? $TMPFILE ; then
               cipher=$(get_cipher $TMPFILE)
               order+=" $cipher"
               tested_cipher="$tested_cipher:-$cipher"
               nr_ciphers_found_r1+=1
               "$FAST" && break
          else
               debugme tmln_out "A: $tested_cipher"
               break
          fi
     done
     batchremoved="${batchremoved//-/}"
     while true; do
          # no ciphers from "ALL$tested_cipher:$batchremoved" left
          # now we check $batchremoved, and remove the minus signs first:
          $OPENSSL s_client $(s_client_options "$STARTTLS -tls1_2 $BUGS -cipher "$batchremoved" -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
          if sclient_connect_successful $? $TMPFILE ; then
               batchremoved_success=true               # signals that we have some of those ciphers and need to put everything together later on
               cipher=$(get_cipher $TMPFILE)
               order+=" $cipher"
               batchremoved="$batchremoved:-$cipher"
               nr_ciphers_found_r1+=1
               debugme tmln_out "B1: $batchremoved"
               "$FAST" && break
          else
               debugme tmln_out "B2: $batchremoved"
               break
               # nothing left with batchremoved ciphers, we need to put everything together
          fi
     done

     if "$batchremoved_success"; then
          # now we combine the two cipher sets from both while loops
          combined_ciphers="$order"
          order="" ; tested_cipher=""
          while true; do
               ciphers_to_test=""
               for cipher in $combined_ciphers; do
                    [[ ! "$tested_cipher:" =~ :-$cipher: ]] && ciphers_to_test+=":$cipher"
               done
               [[ -z "$ciphers_to_test" ]] && break
               $OPENSSL s_client $(s_client_options "$STARTTLS -tls1_2 $BUGS -cipher "${ciphers_to_test:1}" -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
               if sclient_connect_successful $? $TMPFILE ; then
                    cipher=$(get_cipher $TMPFILE)
                    order+=" $cipher"
                    tested_cipher="$tested_cipher:-$cipher"
                    nr_ciphers_found_r2+=1
                    "$FAST" && break
               else
                    # This shouldn't happen.
                    break
               fi
          done
          if "$FAST" && [[ $nr_ciphers_found_r2 -ne 1 ]]; then
                prln_fixme "something weird happened around line $((LINENO - 14))"
                return 1
          elif ! "$FAST" && [[ $nr_ciphers_found_r2 -ne $nr_ciphers_found_r1 ]]; then
                prln_fixme "something weird happened around line $((LINENO - 16))"
                return 1
          fi
     fi
     tm_out "$order"

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


cipher_pref_check() {
     local p="$1" proto_hex="$2" proto="$3"
     local using_sockets="$4"
     local tested_cipher cipher order rfc_cipher rfc_order
     local overflow_probe_cipherlist="ALL:-ECDHE-RSA-AES256-GCM-SHA384:-AES128-SHA:-DES-CBC3-SHA"
     local -i i nr_ciphers nr_nonossl_ciphers num_bundles mod_check bundle_size bundle end_of_bundle success
     local hexc ciphers_to_test
     local -a rfc_ciph hexcode ciphers_found ciphers_found2
     local -a -i index
     local ciphers_found_with_sockets

     order=""; ciphers_found_with_sockets=false
     if [[ $p == ssl3 ]] && ! "$HAS_SSL3" && ! "$using_sockets"; then
          out "\n    SSLv3:     "; pr_local_problem "$OPENSSL doesn't support \"s_client -ssl3\"";
          return 0
     fi
     if [[ $p == tls1_3 ]] && ! "$HAS_TLS13" && ! "$using_sockets"; then
          out "\n    TLSv1.3    "; pr_local_problem "$OPENSSL doesn't support \"s_client -tls1_3\"";
          return 0
     fi

     [[ $(has_server_protocol "$p") -eq 1 ]] && return 0

     if ( [[ $p != tls1_3 ]] || "$HAS_TLS13" ) && ( [[ $p != ssl3 ]] || "$HAS_SSL3" ); then
          if [[ $p == tls1_2 ]] && "$SERVER_SIZE_LIMIT_BUG"; then
               order="$(check_tls12_pref)"
          else
               tested_cipher=""
               while true; do
                    if [[ $p != tls1_3 ]]; then
                         ciphers_to_test="-cipher ALL:COMPLEMENTOFALL${tested_cipher}"
                    else
                         ciphers_to_test=""
                         for cipher in $(colon_to_spaces "$TLS13_OSSL_CIPHERS"); do
                              [[ ! "$tested_cipher" =~ ":-"$cipher ]] && ciphers_to_test+=":$cipher"
                         done
                         [[ -z "$ciphers_to_test" ]] && break
                         ciphers_to_test="-ciphersuites ${ciphers_to_test:1}"
                    fi
                    $OPENSSL s_client $(s_client_options "$STARTTLS -"$p" $BUGS $ciphers_to_test -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>>$ERRFILE >$TMPFILE
                    sclient_connect_successful $? $TMPFILE || break
                    cipher=$(get_cipher $TMPFILE)
                    [[ -z "$cipher" ]] && break
                    order+="$cipher "
                    tested_cipher+=":-"$cipher
                    "$FAST" && break
               done
          fi
     fi

     nr_nonossl_ciphers=0
     if "$using_sockets"; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               ciphers_found[i]=false
               hexc="${TLS_CIPHER_HEXCODE[i]}"
               if [[ ${#hexc} -eq 9 ]]; then
                    if [[ " $order " =~ " ${TLS_CIPHER_OSSL_NAME[i]} " ]]; then
                         ciphers_found[i]=true
                    else
                         ciphers_found2[nr_nonossl_ciphers]=false
                         hexcode[nr_nonossl_ciphers]="${hexc:2:2},${hexc:7:2}"
                         rfc_ciph[nr_nonossl_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                         index[nr_nonossl_ciphers]=$i
                         # Only test ciphers that are relevant to the protocol.
                         if [[ "$p" == tls1_3 ]]; then
                              [[ "${hexc:2:2}" == "13" ]] && nr_nonossl_ciphers+=1
                         elif [[ "$p" == tls1_2 ]]; then
                              [[ "${hexc:2:2}" != 13 ]] && nr_nonossl_ciphers+=1
                         elif [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA256 ]] && \
                              [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA384 ]] && \
                              [[ "${TLS_CIPHER_RFC_NAME[i]}" != *"_CCM" ]] && \
                              [[ "${TLS_CIPHER_RFC_NAME[i]}" != *"_CCM_8" ]]; then
                              nr_nonossl_ciphers+=1
                         fi
                    fi
               fi
          done
     fi

     if [[ $nr_nonossl_ciphers -eq 0 ]]; then
          num_bundles=0
     elif [[ $p != tls1_2 ]] || ! "$SERVER_SIZE_LIMIT_BUG"; then
          num_bundles=1
          bundle_size=$nr_nonossl_ciphers
     else
          num_bundles=$nr_nonossl_ciphers/128
          mod_check=$nr_nonossl_ciphers%128
          [[ $mod_check -ne 0 ]] && num_bundles=$num_bundles+1

          bundle_size=$nr_nonossl_ciphers/$num_bundles
          mod_check=$nr_nonossl_ciphers%$num_bundles
          [[ $mod_check -ne 0 ]] && bundle_size+=1
     fi

     for (( bundle=0; bundle < num_bundles; bundle++ )); do
          end_of_bundle=$bundle*$bundle_size+$bundle_size
          [[ $end_of_bundle -gt $nr_nonossl_ciphers ]] && end_of_bundle=$nr_nonossl_ciphers
          while true; do
               ciphers_to_test=""
               for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                    ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode[i]}"
               done
               [[ -z "$ciphers_to_test" ]] && break
               tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
               [[ $? -ne 0 ]] && break
               cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
               for (( i=bundle*bundle_size; i < end_of_bundle; i++ )); do
                    [[ "$cipher" == "${rfc_ciph[i]}" ]] && ciphers_found2[i]=true && break
               done
               i=${index[i]}
               ciphers_found[i]=true
               ciphers_found_with_sockets=true
               if [[ $p != tls1_2 ]] || ! "$SERVER_SIZE_LIMIT_BUG"; then
                    # Throw out the results found so far and start over using just sockets
                    bundle=$num_bundles
                    for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
                         ciphers_found[i]=true
                    done
                    break
               fi
          done
     done

     # If additional ciphers were found using sockets and there is no
     # SERVER_SIZE_LIMIT_BUG, then just use sockets to find the cipher order.
     # If there is a SERVER_SIZE_LIMIT_BUG, then use sockets to find the cipher
     # order, but starting with the list of ciphers supported by the server.
     if "$ciphers_found_with_sockets"; then
          order=""
          nr_ciphers=0
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               hexc="${TLS_CIPHER_HEXCODE[i]}"
               if "${ciphers_found[i]}" && [[ ${#hexc} -eq 9 ]]; then
                    ciphers_found2[nr_ciphers]=false
                    hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2}"
                    rfc_ciph[nr_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                    if [[ "$p" == "tls1_3" ]]; then
                         [[ "${hexc:2:2}" == "13" ]] && nr_ciphers+=1
                    elif [[ "$p" == "tls1_2" ]]; then
                         [[ "${hexc:2:2}" != "13" ]] && nr_ciphers+=1
                    elif [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA256 ]] && \
                         [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA384 ]] && \
                         [[ "${TLS_CIPHER_RFC_NAME[i]}" != *"_CCM" ]] && \
                         [[ "${TLS_CIPHER_RFC_NAME[i]}" != *"_CCM_8" ]]; then
                         nr_ciphers+=1
                    fi
               fi
          done
          while true; do
               ciphers_to_test=""
               for (( i=0; i < nr_ciphers; i++ )); do
                    ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode[i]}"
               done
               [[ -z "$ciphers_to_test" ]] && break
               tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
               [[ $? -ne 0 ]] && break
               cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
               for (( i=0; i < nr_ciphers; i++ )); do
                    [[ "$cipher" == ${rfc_ciph[i]} ]] && ciphers_found2[i]=true && break
               done
               if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ $TLS_NR_CIPHERS -ne 0 ]]; then
                    cipher="$(rfc2openssl "$cipher")"
                    # If there is no OpenSSL name for the cipher, then use the RFC name
                    [[ -z "$cipher" ]] && cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
               fi
               order+="$cipher "
          done
     elif [[ -n "$order" ]] && [[ "$DISPLAY_CIPHERNAMES" =~ rfc ]]; then
          rfc_order=""
          while read -d " " cipher; do
               rfc_cipher="$(openssl2rfc "$cipher")"
               if [[ -n "$rfc_cipher" ]]; then
                    rfc_order+="$rfc_cipher "
               else
                    rfc_order+="$cipher "
               fi
          done <<< "$order"
          order="$rfc_order"
     fi

     if [[ -n "$order" ]]; then
          add_tls_offered "$p" yes
          outln
          out "$(printf "    %-10s " "$proto: ")"
          if [[ "$COLOR" -le 2 ]]; then
               out "$(out_row_aligned_max_width "$order" "               " $TERM_WIDTH)"
          else
               out_row_aligned_max_width_by_entry "$order" "               " $TERM_WIDTH pr_cipher_quality
          fi
          fileout "cipherorder_${proto//./_}" "INFO" "$order"
     fi

     tmpfile_handle ${FUNCNAME[0]}-$p.txt
     return 0
}


# arg1 is OpenSSL s_client parameter or empty
#
get_host_cert() {
     local tmpvar=$TEMPDIR/${FUNCNAME[0]}.txt     # change later to $TMPFILE

     $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI $1") 2>/dev/null </dev/null >$tmpvar
     if sclient_connect_successful $? $tmpvar; then
          awk '/-----BEGIN/,/-----END/ { print $0 }' $tmpvar >$HOSTCERT
          return 0
     else
          if [[ -z "$1" ]]; then
                prln_warning "could not retrieve host certificate!"
                fileout "host_certificate_Problem" "WARN" "Could not retrieve host certificate!"
          fi
          return 1
     fi
     #tmpfile_handle ${FUNCNAME[0]}.txt
     #return $((${PIPESTATUS[0]} + ${PIPESTATUS[1]}))
}

verify_retcode_helper() {
     local ret=0
     local -i retcode=$1

     case $retcode in
          # codes from ./doc/apps/verify.pod | verify(1ssl)
          44) tm_out "(different CRL scope)" ;;                  # X509_V_ERR_DIFFERENT_CRL_SCOPE
          26) tm_out "(unsupported certificate purpose)" ;;      # X509_V_ERR_INVALID_PURPOSE
          24) tm_out "(certificate unreadable)" ;;               # X509_V_ERR_INVALID_CA
          23) tm_out "(certificate revoked)" ;;                  # X509_V_ERR_CERT_REVOKED
          21) tm_out "(chain incomplete, only 1 cert provided)" ;;    # X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE
          20) tm_out "(chain incomplete)" ;;                     # X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY
          19) tm_out "(self signed CA in chain)" ;;              # X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN
          18) tm_out "(self signed)" ;;                          # X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT
          10) tm_out "(expired)" ;;                              # X509_V_ERR_CERT_HAS_EXPIRED
          9)  tm_out "(not yet valid)" ;;                        # X509_V_ERR_CERT_NOT_YET_VALID
          2)  tm_out "(issuer cert missing)" ;;                  # X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT
          *) ret=1 ; tm_out " (unknown, pls report) $1" ;;
     esac
     return $ret
}

# arg1: number of certificate if provided >1
determine_trust() {
     local jsonID="$1"
     local json_postfix="$2"
     local -i i=1
     local -i num_ca_bundles=0
     local bundle_fname=""
     local -a certificate_file verify_retcode trust
     local ok_was=""
     local notok_was=""
     local all_ok=true
     local some_ok=false
     local code
     local ca_bundles=""
     local spaces="                              "
     local -i certificates_provided=1+$(grep -c "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TEMPDIR/intermediatecerts.pem)
     local addtl_warning

     # If $json_postfix is not empty, then there is more than one certificate
     # and the output should should be indented by two more spaces.
     [[ -n $json_postfix ]] && spaces="                                "

     case $OSSL_VER_MAJOR.$OSSL_VER_MINOR in
          1.0.2|1.1.0|1.1.1|2.[1-9].*|3.*)           # 2.x is LibreSSL. 2.1.1 was tested to work, below is not sure
              :
          ;;
          *)   addtl_warning="Your $OPENSSL <= 1.0.2 might be too unreliable to determine trust"
               fileout "${jsonID}${json_postfix}" "WARN" "$addtl_warning"
               addtl_warning="(${addtl_warning})"
          ;;
     esac
     debugme tmln_out

     # if you run testssl.sh from a different path /you can set either TESTSSL_INSTALL_DIR or CA_BUNDLES_PATH to find the CA BUNDLES
     if [[ -z "$CA_BUNDLES_PATH" ]]; then
          ca_bundles="$TESTSSL_INSTALL_DIR/etc/*.pem"
     else
          ca_bundles="$CA_BUNDLES_PATH/*.pem"
     fi
     for bundle_fname in $ca_bundles; do
          certificate_file[i]=$(basename ${bundle_fname//.pem})
          if [[ ! -r $bundle_fname ]]; then
               prln_warning "\"$bundle_fname\" cannot be found / not readable"
               return 1
          fi
          debugme printf -- " %-12s" "${certificate_file[i]}"
          # Set SSL_CERT_DIR to /dev/null so that $OPENSSL verify will only use certificates in $bundle_fname
          # in a subshell because that should be valid here only
          (export SSL_CERT_DIR="/dev/null"; export SSL_CERT_FILE="/dev/null"
          if [[ $certificates_provided -ge 2 ]]; then
               $OPENSSL verify -purpose sslserver -CAfile <(cat $ADDITIONAL_CA_FILES "$bundle_fname") -untrusted $TEMPDIR/intermediatecerts.pem $HOSTCERT >$TEMPDIR/${certificate_file[i]}.1 2>$TEMPDIR/${certificate_file[i]}.2
          else
               $OPENSSL verify -purpose sslserver -CAfile <(cat $ADDITIONAL_CA_FILES "$bundle_fname") $HOSTCERT >$TEMPDIR/${certificate_file[i]}.1 2>$TEMPDIR/${certificate_file[i]}.2
          fi)
          verify_retcode[i]=$(awk '/error [1-9][0-9]? at [0-9]+ depth lookup:/ { if (!found) {print $2; found=1} }' $TEMPDIR/${certificate_file[i]}.1 $TEMPDIR/${certificate_file[i]}.2)
          [[ -z "${verify_retcode[i]}" ]] && verify_retcode[i]=0
          if [[ ${verify_retcode[i]} -eq 0 ]]; then
               trust[i]=true
               some_ok=true
               [[ -z "$GOOD_CA_BUNDLE" ]] && GOOD_CA_BUNDLE="$bundle_fname"
               debugme tm_svrty_good "Ok   "
               debugme tmln_out "${verify_retcode[i]}"
          else
               trust[i]=false
               all_ok=false
               debugme tm_svrty_high "not trusted "
               debugme tmln_out "${verify_retcode[i]}"
          fi
          ((i++))
     done
     num_ca_bundles=$((i - 1))
     debugme tm_out " "
     if "$all_ok"; then
          # all stores ok
          pr_svrty_good "Ok   "; pr_warning "$addtl_warning"
          # we did to stdout the warning above already, so we could stay here with OK:
          fileout "${jsonID}${json_postfix}" "OK" "passed. $addtl_warning"
     else
          # at least one failed
          pr_svrty_critical "NOT ok"
          if ! "$some_ok"; then
               # all failed (we assume with the same issue), we're displaying the reason
               out " "
               code="$(verify_retcode_helper "${verify_retcode[1]}")"
               if [[ "$code" =~ "pls report" ]]; then
                    pr_warning "$code"
               else
                    out "$code"
               fi
               fileout "${jsonID}${json_postfix}" "CRITICAL" "failed $code. $addtl_warning"
          else
               # is one ok and the others not ==> display the culprit store
               if "$some_ok"; then
                    pr_svrty_critical ":"
                    for ((i=1;i<=num_ca_bundles;i++)); do
                         if ${trust[i]}; then
                              ok_was="${certificate_file[i]} $ok_was"
                         else
                              #code="$(verify_retcode_helper ${verify_retcode[i]})"
                              #notok_was="${certificate_file[i]} $notok_was"
                              pr_svrty_high " ${certificate_file[i]} "
                              code="$(verify_retcode_helper "${verify_retcode[i]}")"
                              if [[ "$code" =~ "pls report" ]]; then
                                   pr_warning "$code"
                              else
                                   out "$code"
                              fi
                              notok_was="${certificate_file[i]} $code $notok_was"
                         fi
                    done
                    #pr_svrty_high "$notok_was "
                    #outln "$code"
                    outln
                    # lf + green ones
                    [[ "$DEBUG" -eq 0 ]] && tm_out "$spaces"
                    pr_svrty_good "OK: $ok_was"
               fi
               fileout "${jsonID}${json_postfix}" "CRITICAL" "Some certificate trust checks failed -> $notok_was $addtl_warning, OK -> $ok_was"
          fi
          [[ -n "$addtl_warning" ]] && out "\n$spaces" && pr_warning "$addtl_warning"
     fi
     outln
     return 0
}

# not handled: Root CA supplied ("contains anchor" in SSLlabs terminology)

tls_time() {
     local difftime
     local spaces="               "
     local jsonID="TLS_timestamp"

     pr_bold " TLS clock skew" ; out "$spaces"

     if ( [[ "$STARTTLS_PROTOCOL" =~ ldap ]] || [[ "$STARTTLS_PROTOCOL" =~ irc ]] ); then
          prln_local_problem "STARTTLS/$STARTTLS_PROTOCOL and --ssl-native collide here"
          return 1
     fi

     TLS_DIFFTIME_SET=true                                       # this is a switch whether we want to measure the remote TLS_TIME
     tls_sockets "01" "$TLS_CIPHER"                              # try first TLS 1.0 (most frequently used protocol)
     [[ -z "$TLS_TIME" ]] && tls_sockets "03" "$TLS12_CIPHER"    #           TLS 1.2
     [[ -z "$TLS_TIME" ]] && tls_sockets "02" "$TLS_CIPHER"      #           TLS 1.1
     [[ -z "$TLS_TIME" ]] && tls_sockets "00" "$TLS_CIPHER"      #           SSL 3

     if [[ -n "$TLS_TIME" ]]; then                               # nothing returned a time!
          difftime=$((TLS_TIME -  TLS_NOW))                      # TLS_NOW has been set in tls_sockets()
          if [[ "${#difftime}" -gt 5 ]]; then
               # openssl >= 1.0.1f fills this field with random values! --> good for possible fingerprint
               out "Random values, no fingerprinting possible "
               fileout "$jsonID" "INFO" "random"
          else
               [[ $difftime != "-"* ]] && [[ $difftime != "0" ]] && difftime="+$difftime"
               out "$difftime"; out " sec from localtime";
               fileout "$jsonID" "INFO" "off by $difftime seconds from your localtime"
          fi
          debugme tm_out "$TLS_TIME"
          outln
     else
          outln "SSLv3 through TLS 1.2 didn't return a timestamp"
          fileout "$jsonID" "INFO" "None returned by SSLv3 through TLSv1.2"
     fi
     TLS_DIFFTIME_SET=false                                      # reset the switch to save calls to date and friend in tls_sockets()
     return 0
}

# core function determining whether handshake succeeded or not
# arg1: return value of "openssl s_client connect"
# arg2: temporary file with the server hello
# returns 0 if connect was successful, 1 if not
#
sclient_connect_successful() {
     local server_hello="$(cat -v "$2")"
     local re='Master-Key: ([^\
]*)'

     [[ $1 -eq 0 ]] && return 0
     if [[ "$server_hello" =~ $re ]]; then
          [[ -n "${BASH_REMATCH[1]}" ]] && return 0
     fi
     [[ "$server_hello" =~ (New|Reused)", "(SSLv[23]|TLSv1(\.[0-3])?(\/SSLv3)?)", Cipher is "([A-Z0-9]+-[A-Za-z0-9\-]+|TLS_[A-Za-z0-9_]+) ]] && return 0
     # what's left now is: master key empty and Session-ID not empty
     # ==> probably client-based auth with x509 certificate. We handle that at other places
     #
     # For robustness we also detected here network / server connectivity problems:
     # Just need to check whether $TMPFILE=$2 is empty
     if [[ ! -s "$2" ]]; then
          ((NR_OSSL_FAIL++))
          connectivity_problem $NR_OSSL_FAIL $MAX_OSSL_FAIL "openssl s_client connect problem" "repeated openssl s_client connect problem, doesn't make sense to continue"
     fi
     return 1
}

extract_new_tls_extensions() {
     local tls_extensions

     # this is not beautiful (grep+sed)
     # but maybe we should just get the ids and do a private matching, according to
     # https://www.iana.org/assignments/tls-extensiontype-values/tls-extensiontype-values.xhtml
     tls_extensions=$(grep -a 'TLS server extension ' "$1" | \
          sed -e 's/TLS server extension //g' -e 's/\" (id=/\/#/g' \
              -e 's/,.*$/,/g' -e 's/),$/\"/g' \
              -e 's/elliptic curves\/#10/supported_groups\/#10/g')
     tls_extensions=$(echo $tls_extensions)       # into one line

     if [[ -n "$tls_extensions" ]]; then
          # check to see if any new TLS extensions were returned and add any new ones to TLS_EXTENSIONS
          while read -d "\"" -r line; do
               if [[ $line != "" ]] && [[ ! "$TLS_EXTENSIONS" =~ "$line" ]]; then
#FIXME: This is a string of quoted strings, so this seems to determine the output format already. Better e.g. would be an array
                    TLS_EXTENSIONS+=" \"${line}\""
               fi
          done <<<$tls_extensions
          [[ "${TLS_EXTENSIONS:0:1}" == " " ]] && TLS_EXTENSIONS="${TLS_EXTENSIONS:1}"
     fi
}

# Note that since, at the moment, this function is only called by run_server_defaults()
# and run_heartbleed(), this function does not look for the status request or NPN
# extensions. For run_heartbleed(), only the heartbeat extension needs to be detected.
# For run_server_defaults(), the status request and NPN would already be detected by
# get_server_certificate(), if they are supported. In the case of the status extension,
# since including a status request extension in a ClientHello does not work for GOST
# only servers. In the case of NPN, since a server will not include both the NPN and
# ALPN extensions in the same ServerHello.
#
determine_tls_extensions() {
     local addcmd
     local -i success=1
     local line params="" tls_extensions=""
     local alpn_proto alpn="" alpn_list_len_hex alpn_extn_len_hex
     local -i alpn_list_len alpn_extn_len
     local cbc_cipher_list="ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA256:DH-RSA-AES256-SHA256:DH-DSS-AES256-SHA256:DHE-RSA-AES256-SHA:DHE-DSS-AES256-SHA:DH-RSA-AES256-SHA:DH-DSS-AES256-SHA:ECDHE-RSA-CAMELLIA256-SHA384:ECDHE-ECDSA-CAMELLIA256-SHA384:DHE-RSA-CAMELLIA256-SHA256:DHE-DSS-CAMELLIA256-SHA256:DH-RSA-CAMELLIA256-SHA256:DH-DSS-CAMELLIA256-SHA256:DHE-RSA-CAMELLIA256-SHA:DHE-DSS-CAMELLIA256-SHA:DH-RSA-CAMELLIA256-SHA:DH-DSS-CAMELLIA256-SHA:ECDH-RSA-AES256-SHA384:ECDH-ECDSA-AES256-SHA384:ECDH-RSA-AES256-SHA:ECDH-ECDSA-AES256-SHA:ECDH-RSA-CAMELLIA256-SHA384:ECDH-ECDSA-CAMELLIA256-SHA384:AES256-SHA256:AES256-SHA:CAMELLIA256-SHA256:CAMELLIA256-SHA:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:DHE-RSA-AES128-SHA256:DHE-DSS-AES128-SHA256:DH-RSA-AES128-SHA256:DH-DSS-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA:DH-RSA-AES128-SHA:DH-DSS-AES128-SHA:ECDHE-RSA-CAMELLIA128-SHA256:ECDHE-ECDSA-CAMELLIA128-SHA256:DHE-RSA-CAMELLIA128-SHA256:DHE-DSS-CAMELLIA128-SHA256:DH-RSA-CAMELLIA128-SHA256:DH-DSS-CAMELLIA128-SHA256:DHE-RSA-SEED-SHA:DHE-DSS-SEED-SHA:DH-RSA-SEED-SHA:DH-DSS-SEED-SHA:DHE-RSA-CAMELLIA128-SHA:DHE-DSS-CAMELLIA128-SHA:DH-RSA-CAMELLIA128-SHA:DH-DSS-CAMELLIA128-SHA:ECDH-RSA-AES128-SHA256:ECDH-ECDSA-AES128-SHA256:ECDH-RSA-AES128-SHA:ECDH-ECDSA-AES128-SHA:ECDH-RSA-CAMELLIA128-SHA256:ECDH-ECDSA-CAMELLIA128-SHA256:AES128-SHA256:AES128-SHA:CAMELLIA128-SHA256:SEED-SHA:CAMELLIA128-SHA:IDEA-CBC-SHA:ECDHE-RSA-DES-CBC3-SHA:ECDHE-ECDSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:EDH-DSS-DES-CBC3-SHA:DH-RSA-DES-CBC3-SHA:DH-DSS-DES-CBC3-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-ECDSA-DES-CBC3-SHA:DES-CBC3-SHA:EXP1024-DHE-DSS-DES-CBC-SHA:EDH-RSA-DES-CBC-SHA:EDH-DSS-DES-CBC-SHA:DH-RSA-DES-CBC-SHA:DH-DSS-DES-CBC-SHA:EXP1024-DES-CBC-SHA:DES-CBC-SHA:EXP-EDH-RSA-DES-CBC-SHA:EXP-EDH-DSS-DES-CBC-SHA:EXP-DES-CBC-SHA:EXP-RC2-CBC-MD5:EXP-DH-DSS-DES-CBC-SHA:EXP-DH-RSA-DES-CBC-SHA"
     local cbc_cipher_list_hex="c0,28, c0,24, c0,14, c0,0a, 00,6b, 00,6a, 00,69, 00,68, 00,39, 00,38, 00,37, 00,36, c0,77, c0,73, 00,c4, 00,c3, 00,c2, 00,c1, 00,88, 00,87, 00,86, 00,85, c0,2a, c0,26, c0,0f, c0,05, c0,79, c0,75, 00,3d, 00,35, 00,c0, 00,84, c0,3d, c0,3f, c0,41, c0,43, c0,45, c0,49, c0,4b, c0,4d, c0,4f, c0,27, c0,23, c0,13, c0,09, 00,67, 00,40, 00,3f, 00,3e, 00,33, 00,32, 00,31, 00,30, c0,76, c0,72, 00,be, 00,bd, 00,bc, 00,bb, 00,9a, 00,99, 00,98, 00,97, 00,45, 00,44, 00,43, 00,42, c0,29, c0,25, c0,0e, c0,04, c0,78, c0,74, 00,3c, 00,2f, 00,ba, 00,96, 00,41, 00,07, c0,3c, c0,3e, c0,40, c0,42, c0,44, c0,48, c0,4a, c0,4c, c0,4e, c0,12, c0,08, 00,16, 00,13, 00,10, 00,0d, c0,0d, c0,03, 00,0a, fe,ff, ff,e0, 00,63, 00,15, 00,12, 00,0f, 00,0c, 00,62, 00,09, fe,fe, ff,e1, 00,14, 00,11, 00,08, 00,06, 00,0b, 00,0e"
     local using_sockets=true

     [[ "$OPTIMAL_PROTO" == -ssl2 ]] && return 0
     "$SSL_NATIVE" && using_sockets=false

     if "$using_sockets"; then
          tls_extensions="00,01,00,01,02, 00,02,00,00, 00,04,00,00, 00,12,00,00, 00,16,00,00, 00,17,00,00"
          if [[ -z $STARTTLS ]]; then
               for alpn_proto in $ALPN_PROTOs; do
                    alpn+=",$(printf "%02x" ${#alpn_proto}),$(string_to_asciihex "$alpn_proto")"
               done
               alpn_list_len=${#alpn}/3
               alpn_list_len_hex=$(printf "%04x" $alpn_list_len)
               alpn_extn_len=$alpn_list_len+2
               alpn_extn_len_hex=$(printf "%04x" $alpn_extn_len)
               tls_extensions+=", 00,10,${alpn_extn_len_hex:0:2},${alpn_extn_len_hex:2:2},${alpn_list_len_hex:0:2},${alpn_list_len_hex:2:2}$alpn"
          fi
          if [[ ! "$TLS_EXTENSIONS" =~ encrypt-then-mac ]]; then
               tls_sockets "03" "$cbc_cipher_list_hex, 00,ff" "all" "$tls_extensions"
               success=$?
          fi
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               tls_sockets "03" "$TLS12_CIPHER" "all" "$tls_extensions"
               success=$?
          fi
          [[ $success -eq 2 ]] && success=0
          [[ $success -eq 0 ]] && extract_new_tls_extensions "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt"
          if [[ -r "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" ]]; then
               cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
               tmpfile_handle ${FUNCNAME[0]}.txt
          fi
     else
          if "$HAS_ALPN" && [[ -z $STARTTLS ]]; then
               params="-alpn \"${ALPN_PROTOs// /,}\""  # we need to replace " " by ","
          elif "$HAS_NPN" && [[ -z $STARTTLS ]]; then
               params="-nextprotoneg \"$NPN_PROTOs\""
          fi
          if [[ -z "$OPTIMAL_PROTO" ]] && [[ -z "$SNI" ]] && "$HAS_NO_SSL2"; then
               addcmd="-no_ssl2"
          else
               addcmd="$SNI"
          fi
          if [[ ! "$TLS_EXTENSIONS" =~ encrypt-then-mac ]]; then
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $addcmd $OPTIMAL_PROTO -tlsextdebug $params -cipher $cbc_cipher_list") </dev/null 2>$ERRFILE >$TMPFILE
               sclient_connect_successful $? $TMPFILE
               success=$?
          fi
          if [[ $success -ne 0 ]]; then
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $addcmd $OPTIMAL_PROTO -tlsextdebug $params") </dev/null 2>$ERRFILE >$TMPFILE
               sclient_connect_successful $? $TMPFILE
               success=$?
          fi
          [[ $success -eq 0 ]] && extract_new_tls_extensions $TMPFILE
          tmpfile_handle ${FUNCNAME[0]}.txt
     fi
     return $success
}

extract_certificates() {
     local version="$1"
     local savedir
     local -i i success nrsaved=0
     local issuerDN CAsubjectDN previssuerDN

     # Place the server's certificate in $HOSTCERT and any intermediate
     # certificates that were provided in $TEMPDIR/intermediatecerts.pem
     savedir=$(pwd); cd $TEMPDIR
     # http://backreference.org/2010/05/09/ocsp-verification-with-openssl/
     if [[ "$version" == ssl2 ]]; then
          awk -v n=-1 '/Server certificate/ {start=1}
               /-----BEGIN CERTIFICATE-----/{ if (start) {inc=1; n++} }
               inc { print > ("level" n ".crt") }
               /---END CERTIFICATE-----/{ inc=0 }' $TMPFILE
     else
          awk -v n=-1 '/Certificate chain/ {start=1}
               /-----BEGIN CERTIFICATE-----/{ if (start) {inc=1; n++} }
               inc { print > ("level" n ".crt") }
               /---END CERTIFICATE-----/{ inc=0 }' $TMPFILE
     fi
     [[ -s level0.crt ]] && nrsaved=$(count_words "$(echo level?.crt 2>/dev/null)")
     if [[ $nrsaved -eq 0 ]]; then
         success=1
     else
         success=0
         CERTIFICATE_LIST_ORDERING_PROBLEM=false
         mv level0.crt $HOSTCERT
         if [[ $nrsaved -eq 1 ]]; then
             echo "" > $TEMPDIR/intermediatecerts.pem
         else
             cat level?.crt > $TEMPDIR/intermediatecerts.pem
             issuerDN="$($OPENSSL x509 -in $HOSTCERT -noout -issuer 2>/dev/null)"
             issuerDN="${issuerDN:8}"
             previssuerDN="$issuerDN"
             # The second certificate (level1.crt) SHOULD be issued to the CA
             # that issued the server's certificate. But, according to RFC 8446
             # clients SHOULD be prepared to handle cases in which the server
             # does not order the certificates correctly.
             for (( i=1; i < nrsaved; i++ )); do
                  CAsubjectDN="$($OPENSSL x509 -in "level$i.crt" -noout -subject  2>/dev/null)"
                  if [[ "${CAsubjectDN:9}" == "$issuerDN" ]]; then
                       cp "level$i.crt" $TEMPDIR/hostcert_issuer.pem
                       issuerDN="" # set to empty to prevent further matches
                  fi
                  [[ "${CAsubjectDN:9}" != "$previssuerDN" ]] && CERTIFICATE_LIST_ORDERING_PROBLEM=true
                  "$CERTIFICATE_LIST_ORDERING_PROBLEM" && [[ -z "$issuerDN" ]] && break
                  previssuerDN="$($OPENSSL x509 -in "level$i.crt" -noout -issuer  2>/dev/null)"
                  previssuerDN="${previssuerDN:8}"
             done
             # This should never happen, but if more than one certificate was
             # provided and none of them belong to the CA that issued the
             # server's certificate, then the extra certificates should just
             # be deleted. There is code elsewhere that assumes that if
             # $TEMPDIR/intermediatecerts.pem is non-empty, then
             # $TEMPDIR/hostcert_issuer.pem is also present.
             [[ -n "$issuerDN" ]] && echo "" > $TEMPDIR/intermediatecerts.pem
             rm level?.crt
         fi
     fi
     cd "$savedir"
     return $success
}

extract_stapled_ocsp() {
     local response="$(cat $TMPFILE)"
     local ocsp tmp
     local -i ocsp_len

     STAPLED_OCSP_RESPONSE=""
     if [[ "$response" =~ CertificateStatus ]]; then
          # This is OpenSSL 1.1.0 or 1.1.1 and the response
          # is TLS 1.2 or earlier.
          ocsp="${response##*CertificateStatus}"
          ocsp="16${ocsp#*16}"
          ocsp="${ocsp%%<<<*}"
          ocsp="$(strip_spaces "$(newline_to_spaces "$ocsp")")"
          ocsp="${ocsp:8}"
     elif [[ "$response" =~ "TLS server extension \"status request\" (id=5), len=0" ]]; then
          # This is not OpenSSL 1.1.0 or 1.1.1, and the response
          # is TLS 1.2 or earlier.
          ocsp="${response%%OCSP response:*}"
          ocsp="${ocsp##*<<<}"
          ocsp="16${ocsp#*16}"
          ocsp="$(strip_spaces "$(newline_to_spaces "$ocsp")")"
          ocsp="${ocsp:8}"
     elif [[ "$response" =~ "TLS server extension \"status request\" (id=5), len=" ]]; then
            # This is OpenSSL 1.1.1 and the response is TLS 1.3.
            ocsp="${response##*TLS server extension \"status request\" (id=5), len=}"
            ocsp="${ocsp%%<<<*}"
            tmp="${ocsp%%[!0-9]*}"
            ocsp="${ocsp#$tmp}"
            ocsp_len=2*$tmp
            ocsp="$(awk ' { print $3 $4 $5 $6 $7 $8 $9 $10 $11 $12 $13 $14 $15 $16 $17 } ' <<< "$ocsp" | sed 's/-//')"
            ocsp="$(strip_spaces "$(newline_to_spaces "$ocsp")")"
            ocsp="${ocsp:0:ocsp_len}"
     else
          return 0
     fi
     # Determine whether this is a single OCSP response or a sequence of
     # responses and then extract just the response for the server's
     # certificate.
     if [[ "${ocsp:0:2}" == "01" ]]; then
          STAPLED_OCSP_RESPONSE="${ocsp:8}"
     elif [[ "${ocsp:0:2}" == "02" ]]; then
          ocsp_len=2*$(hex2dec "${tls_certificate_status_ascii:8:6}")
          STAPLED_OCSP_RESPONSE="${ocsp:14:ocsp_len}"
     fi
     return 0
}

# arg1 is "<OpenSSL cipher>"
# arg2 is a list of protocols to try (tls1_2, tls1_1, tls1, ssl3) or empty (if all should be tried)
get_server_certificate() {
     local protocols_to_try proto
     local success ret
     local npn_params="" line
     local ciphers_to_test=""
     # Cipher suites that use a certifiate with an RSA (signature) public key
     local -r a_rsa="cc,13, cc,15, c0,30, c0,28, c0,14, 00,9f, cc,a8, cc,aa, c0,a3, c0,9f, 00,6b, 00,39, c0,77, 00,c4, 00,88, c0,45, c0,4d, c0,53, c0,61, c0,7d, c0,8b, 16,b7, 16,b9, c0,2f, c0,27, c0,13, 00,9e, c0,a2, c0,9e, 00,67, 00,33, c0,76, 00,be, 00,9a, 00,45, c0,44, c0,4c, c0,52, c0,60, c0,7c, c0,8a, c0,11, c0,12, 00,16, 00,15, 00,14, c0,10"
     # Cipher suites that use a certifiate with an RSA (encryption) public key
     local -r e_rsa="00,b7, c0,99, 00,ad, cc,ae, 00,9d, c0,a1, c0,9d, 00,3d, 00,35, 00,c0, 00,84, 00,95, c0,3d, c0,51, c0,69, c0,6f, c0,7b, c0,93, ff,01, 00,ac, c0,a0, c0,9c, 00,9c, 00,3c, 00,2f, 00,ba, 00,b6, 00,96, 00,41, c0,98, 00,07, 00,94, c0,3c, c0,50, c0,68, c0,6e, c0,7a, c0,92, 00,05, 00,04, 00,92, 00,0a, 00,93, fe,ff, ff,e0, 00,62, 00,09, 00,61, fe,fe, ff,e1, 00,64, 00,60, 00,08, 00,06, 00,03, 00,b9, 00,b8, 00,2e, 00,3b, 00,02, 00,01, ff,00"
     # Cipher suites that use a certifiate with a DSA public key
     local -r a_dss="00,a3, 00,6a, 00,38, 00,c3, 00,87, c0,43, c0,57, c0,81, 00,a2, 00,40, 00,32, 00,bd, 00,99, 00,44, c0,42, c0,56, c0,80, 00,66, 00,13, 00,63, 00,12, 00,65, 00,11"
     # Cipher suites that use a certifiate with a DH public key
     local -r a_dh="00,a5, 00,a1, 00,69, 00,68, 00,37, 00,36, 00,c2, 00,c1, 00,86, 00,85, c0,3f, c0,41, c0,55, c0,59, c0,7f, c0,83, 00,a4, 00,a0, 00,3f, 00,3e, 00,31, 00,30, 00,bc, 00,bb, 00,98, 00,97, 00,43, 00,42, c0,3e, c0,40, c0,54, c0,58, c0,7e, c0,82, 00,10, 00,0d, 00,0f, 00,0c, 00,0b, 00,0e"
     # Cipher suites that use a certifiate with an ECDH public key
     local -r a_ecdh="c0,32, c0,2e, c0,2a, c0,26, c0,0f, c0,05, c0,79, c0,75, c0,4b, c0,4f, c0,5f, c0,63, c0,89, c0,8d, c0,31, c0,2d, c0,29, c0,25, c0,0e, c0,04, c0,78, c0,74, c0,4a, c0,4e, c0,5e, c0,62, c0,88, c0,8c, c0,0c, c0,02, c0,0d, c0,03, c0,0b, c0,01"
     # Cipher suites that use a certifiate with an ECDSA public key
     local -r a_ecdsa="cc,14, c0,2c, c0,24, c0,0a, cc,a9, c0,af, c0,ad, c0,73, c0,49, c0,5d, c0,87, 16,b8, 16,ba, c0,2b, c0,23, c0,09, c0,ae, c0,ac, c0,72, c0,48, c0,5c, c0,86, c0,07, c0,08, c0,06"
     # Cipher suites that use a certifiate with a GOST public key
     local -r a_gost="00,80, 00,81, 00,82, 00,83"
     local using_sockets=true

     "$SSL_NATIVE" && using_sockets=false

     CERTIFICATE_LIST_ORDERING_PROBLEM=false
     if [[ "$1" =~ "tls1_3" ]]; then
          [[ $(has_server_protocol "tls1_3") -eq 1 ]] && return 1
          if "$HAS_TLS13"; then
               if [[ "$1" =~ "tls1_3_RSA" ]]; then
                    $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -showcerts -connect $NODEIP:$PORT $PROXY $SNI -tls1_3 -tlsextdebug -status -msg -sigalgs PSS+SHA256:PSS+SHA384") </dev/null 2>$ERRFILE >$TMPFILE
               elif [[ "$1" =~ "tls1_3_ECDSA" ]]; then
                    $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -showcerts -connect $NODEIP:$PORT $PROXY $SNI -tls1_3 -tlsextdebug -status -msg -sigalgs ECDSA+SHA256:ECDSA+SHA384") </dev/null 2>$ERRFILE >$TMPFILE
               else
                    return 1
               fi
               sclient_connect_successful $? $TMPFILE || return 1
               DETECTED_TLS_VERSION="0304"
               extract_certificates "tls1_3"
               extract_stapled_ocsp
               success=$?
          else
               # For STARTTLS protcols not being implemented yet via sockets this is a bypass otherwise it won't be usable at all (e.g. LDAP)
               if ( [[ "$STARTTLS" =~ ldap ]] || [[ "$STARTTLS" =~ irc ]] ); then
                    return 1
               elif [[ "$1" =~ "tls1_3_RSA" ]]; then
                    tls_sockets "04" "$TLS13_CIPHER" "all" "00,12,00,00, 00,05,00,05,01,00,00,00,00, 00,0d,00,10,00,0e,08,04,08,05,08,06,04,01,05,01,06,01,02,01"
               elif [[ "$1" =~ "tls1_3_ECDSA" ]]; then
                    tls_sockets "04" "$TLS13_CIPHER" "all" "00,12,00,00, 00,05,00,05,01,00,00,00,00, 00,0d,00,0a,00,08,04,03,05,03,06,03,02,03"
               else
                    return 1
               fi
               success=$?
               [[ $success -eq 0 ]] || return 1
               cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
          fi
          [[ $success -eq 0 ]] && add_tls_offered tls1_3 yes
          extract_new_tls_extensions $TMPFILE
          tmpfile_handle ${FUNCNAME[0]}.txt
          return $success
     fi

     "$HAS_NPN" && [[ -z "$STARTTLS" ]] && npn_params="-nextprotoneg \"$NPN_PROTOs\""

     if [[ -n "$2" ]]; then
         protocols_to_try="$2"
     else
         protocols_to_try="tls1_2 tls1_1 tls1 ssl3"
     fi

     # throwing 1st every cipher/protocol at the server to know what works
     success=7

     if [[ "$OPTIMAL_PROTO" == -ssl2 ]]; then
          success=1
          sslv2_sockets "" "true"
          if [[ $? -eq 3 ]]; then
               mv $TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt $TMPFILE
               success=0
          fi
          tmpfile_handle ${FUNCNAME[0]}.txt
          return $success
     fi

     if "$using_sockets"; then
          protocols_to_try="${protocols_to_try/tls1_2/03}"
          protocols_to_try="${protocols_to_try/tls1_1/02}"
          protocols_to_try="${protocols_to_try/tls1/01}"
          protocols_to_try="${protocols_to_try/ssl3/00}"

          [[ "$1" =~ aRSA ]] && ciphers_to_test+=", $a_rsa"
          [[ "$1" =~ eRSA ]] && ciphers_to_test+=", $e_rsa"
          [[ "$1" =~ aDSS ]] && ciphers_to_test+=", $a_dss"
          [[ "$1" =~ aDH ]] && ciphers_to_test+=", $a_dh"
          [[ "$1" =~ aECDH ]] && ciphers_to_test+=", $a_ecdh"
          [[ "$1" =~ aECDSA ]] && ciphers_to_test+=", $a_ecdsa"
          [[ "$1" =~ aGOST ]] && ciphers_to_test+=", $a_gost"

          [[ -z "$ciphers_to_test" ]] && return 1
          ciphers_to_test="${ciphers_to_test:2}"

          for proto in $protocols_to_try; do
               [[ 1 -eq $(has_server_protocol $proto) ]] && continue
               tls_sockets "$proto" "$ciphers_to_test, 00,ff" "all" "00,12,00,00, 00,05,00,05,01,00,00,00,00"
               ret=$?
               [[ $ret -eq 0 ]] && success=0 && break
               [[ $ret -eq 2 ]] && success=0 && break
          done                          # this loop is needed for IIS6 and others which have a handshake size limitations
          if [[ $success -eq 7 ]]; then
               # "-status" above doesn't work for GOST only servers, so we do another test without it and see whether that works then:
               tls_sockets "$proto" "$ciphers_to_test, 00,ff" "all" "00,12,00,00"
               ret=$?
               [[ $ret -eq 0 ]] && success=0
               [[ $ret -eq 2 ]] && success=0
               if [[ $success -eq 7 ]]; then
                    if [ -z "$1" ]; then
                        prln_warning "Strange, no SSL/TLS protocol seems to be supported (error around line $((LINENO - 6)))"
                    fi
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 7  # this is ugly, I know
               else
                    GOST_STATUS_PROBLEM=true
               fi
          fi
          cp $TEMPDIR/$NODEIP.parse_tls_serverhello.txt $TMPFILE

          # When "$2" is empty, get_server_certificate() is being called with SNI="".
          # In case the extensions returned by the server differ depending on wheter
          # SNI is provided or not, don't collect extensions when SNI="" (unless
          # no DNS name was provided at the command line).
          [[ -z "$2" ]] && extract_new_tls_extensions $TMPFILE
     else
          ciphers_to_test="$1"
          if [[ "$1" =~ aRSA ]] && [[ "$1" =~ eRSA ]]; then
               ciphers_to_test="${ciphers_to_test/eRSA/}"
          elif [[ "$1" =~ aRSA ]]; then
               ciphers_to_test="${ciphers_to_test/aRSA/}"
               for ciph in $(colon_to_spaces $(actually_supported_ciphers "aRSA")); do
                    [[ "$ciph" =~ -RSA- ]] && ciphers_to_test+=":$ciph"
               done
          elif [[ "$1" =~ eRSA ]]; then
               ciphers_to_test="${ciphers_to_test/eRSA/}"
               for ciph in $(colon_to_spaces $(actually_supported_ciphers "aRSA")); do
                    [[ ! "$ciph" =~ -RSA- ]] && ciphers_to_test+=":$ciph"
               done
          fi
          ciphers_to_test="${ciphers_to_test/::/:}"
          [[ "${ciphers_to_test:0:1}" == : ]] &&  ciphers_to_test="${ciphers_to_test:1}"
          [[ $(count_ciphers $(actually_supported_ciphers "$ciphers_to_test")) -ge 1 ]] || return 1

          for proto in $protocols_to_try; do
               [[ 1 -eq $(has_server_protocol $proto) ]] && continue
               [[ "$proto" == ssl3 ]] && ! "$HAS_SSL3" && continue
               addcmd=""
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -cipher $ciphers_to_test -showcerts -connect $NODEIP:$PORT $PROXY $SNI -$proto -tlsextdebug $npn_params -status -msg") </dev/null 2>$ERRFILE >$TMPFILE
               if sclient_connect_successful $? $TMPFILE; then
                    success=0
                    break               # now we have the certificate
               fi
          done                          # this loop is needed for IIS6 and others which have a handshake size limitations
          if [[ $success -eq 7 ]]; then
               # "-status" above doesn't work for GOST only servers, so we do another test without it and see whether that works then:
               [[ "$proto" == ssl3 ]] && ! "$HAS_SSL3" && return 7
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -cipher $ciphers_to_test -showcerts -connect $NODEIP:$PORT $PROXY $SNI -$proto -tlsextdebug") </dev/null 2>>$ERRFILE >$TMPFILE
               if ! sclient_connect_successful $? $TMPFILE; then
                    if [ -z "$1" ]; then
                        prln_warning "Strange, no SSL/TLS protocol seems to be supported (error around line $((LINENO - 6)))"
                    fi
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 7  # this is ugly, I know
               else
                    GOST_STATUS_PROBLEM=true
               fi
          fi
          case "$proto" in
               "tls1_2") DETECTED_TLS_VERSION="0303" ;;
               "tls1_1") DETECTED_TLS_VERSION="0302" ;;
               "tls1") DETECTED_TLS_VERSION="0301" ;;
               "ssl3") DETECTED_TLS_VERSION="0300" ;;
          esac
          # When "$2" is empty, get_server_certificate() is being called with SNI="".
          # In case the extensions returned by the server differ depending on wheter
          # SNI is provided or not, don't collect extensions when SNI="" (unless
          # no DNS name was provided at the command line).
          [[ -z "$2" ]] && extract_new_tls_extensions $TMPFILE

          extract_certificates "$proto"
          extract_stapled_ocsp
          success=$?
     fi
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $success
}

# arg1: path to certificate
# returns CN
get_cn_from_cert() {
     local subject

     # attention! openssl 1.0.2 doesn't properly handle online output from certificates from trustwave.com/github.com
     #FIXME: use -nameopt oid for robustness

     # for e.g. russian sites -esc_msb,utf8 works in an UTF8 terminal -- any way to check platform independent?
     # see x509(1ssl):
     subject="$($OPENSSL x509 -in $1 -noout -subject -nameopt multiline,-align,sname,-esc_msb,utf8,-space_eq 2>>$ERRFILE)"
     echo "$(awk -F'=' '/CN=/ { print $2 }' <<< "$subject" | tr '\n' ' ')"
     return $?
}

# Return 0 if the name provided in arg1 is a wildcard name
is_wildcard()
{
     local certname="$1"

     # If the first label in the DNS name begins "xn--", then assume it is an
     # A-label and not a wildcard name (RFC 6125, Section 6.4.3).
     [[ "${certname:0:4}" == "xn--" ]] && return 1

     # Remove part of name preceding '*' or '.'. If no "*" appears in the
     # left-most label, then it is not a wildcard name (RFC 6125, Section 6.4.3).
     basename="$(echo -n "$certname" | sed 's/^[_a-zA-Z0-9\-]*//')"
     [[ "${basename:0:1}" != "*" ]] && return 1 # not a wildcard name

     # Check that there are no additional wildcard ('*') characters or any
     # other characters that do not belong in a DNS name.
     [[ -n $(echo -n "${basename:1}" | sed 's/^[_\.a-zA-Z0-9\-]*//') ]] && return 1
     return 0
}

# Return 0 if the name provided in arg2 is a wildcard name and it matches the name provided in arg1.
wildcard_match()
{
     local servername="$1"
     local certname="$2"
     local basename
     local -i basename_offset len_certname len_part1 len_basename
     local -i len_servername len_wildcard

     len_servername=${#servername}
     len_certname=${#certname}

     # Use rules from RFC 6125 to perform the match.

     # Assume the "*" in the wildcard needs to be replaced by one or more
     # characters, although RFC 6125 is not clear about that.
     [[ $len_servername -lt $len_certname ]] && return 1

     is_wildcard "$certname"
     [[ $? -ne 0 ]] && return 1

     # Comparisons of DNS names are case insensitive, so convert both names to uppercase.
     certname="$(toupper "$certname")"
     servername="$(toupper "$servername")"

     # Extract part of name that comes after the "*"
     basename="$(echo -n "$certname" | sed 's/^[_A-Z0-9\-]*\*//')"
     len_basename=${#basename}
     len_part1=$len_certname-$len_basename-1
     len_wildcard=$len_servername-$len_certname+1
     basename_offset=$len_servername-$len_basename

     # Check that initial part of $servername matches initial part of $certname
     # and that final part of $servername matches final part of $certname.
     [[ "${servername:0:len_part1}" != "${certname:0:len_part1}" ]] && return 1
     [[ "${servername:basename_offset:len_basename}" != "$basename" ]] && return 1

     # Check that part of $servername that matches "*" is all part of a single
     # domain label.
     [[ -n $(echo -n "${servername:len_part1:len_wildcard}" | sed 's/^[_A-Z0-9\-]*//') ]] && return 1

     return 0
}

# Compare the server name provided in arg1 to the CN and SAN in arg2 and return:
#    0, if server name provided does not match any of the names in the CN or SAN
#    1, if the server name provided matches a name in the SAN
#    2, if the server name provided is a wildcard match against a name in the SAN
#    4, if the server name provided matches the CN
#    5, if the server name provided matches the CN AND a name in the SAN
#    6, if the server name provided matches the CN AND is a wildcard match against a name in the SAN
#    8, if the server name provided is a wildcard match against the CN
#    9, if the server name provided matches a name in the SAN AND is a wildcard match against the CN
#   10, if the server name provided is a wildcard match against the CN AND a name in the SAN

compare_server_name_to_cert() {
     local cert="$1"
     local servername cn dns_sans ip_sans san dercert tag
     local srv_id="" xmppaddr=""
     local -i i len len1
     local -i subret=0             # no error condition, passing results

     HAS_DNS_SANS=false
     if [[ -n "$XMPP_HOST" ]]; then
          # RFC 6120, Section 13.7.2.1, states that for XMPP the identity that
          # should appear in the server's certificate is identity that appears
          # in the the 'to' address that the client communicates in the initial
          # stream header.
          servername="$(toupper "$XMPP_HOST")"
     else
          servername="$(toupper "$NODE")"
     fi

     # Check whether any of the DNS names in the certificate match the servername
     dns_sans="$(get_san_dns_from_cert "$cert")"
     while read san; do
          if [[ -n "$san" ]]; then
               HAS_DNS_SANS=true
               [[ $(toupper "$san") == "$servername" ]] && subret=1 && break
          fi
     done <<< "$dns_sans"

     if [[ $subret -eq 0 ]]; then
          # Check whether any of the IP addresses in the certificate match the servername
          ip_sans=$($OPENSSL x509 -in "$cert" -noout -text 2>>$ERRFILE | grep -A2 "Subject Alternative Name" | \
                  tr ',' '\n' | grep "IP Address:" | sed -e 's/IP Address://g' -e 's/ //g')
          while read san; do
               [[ -n "$san" ]] && [[ "$san" == "$servername" ]] && subret=1 && break
          done <<< "$ip_sans"
     fi

     if [[ $subret -eq 0 ]] && [[ -n "$XMPP_HOST" ]]; then
          # For XMPP hosts, in addition to checking for a matching DNS name,
          # should also check for a matching SRV-ID or XmppAddr identifier.
          dercert="$($OPENSSL x509 -in "$cert" -outform DER 2>>$ERRFILE | hexdump -v -e '16/1 "%02X"')"
          # Look for the beginning of the subjectAltName extension. It
          # will begin with the OID (2.5.29.17 = 0603551D11). After the OID
          # there may be an indication that the extension is critical (0101FF).
          # Finally will be the tag indicating that the value of the extension is
          # encoded as an OCTET STRING (04).
          if [[ "$dercert" =~ 0603551D110101FF04 ]]; then
               dercert="${dercert##*0603551D110101FF04}"
          else
               dercert="${dercert##*0603551D1104}"
          fi
          # Skip over the encoding of the length of the OCTET STRING.
          if [[ "${dercert:0:1}" == "8" ]]; then
               i="${dercert:1:1}"
               i=2*$i+2
               dercert="${dercert:i}"
          else
               dercert="${dercert:2}"
          fi
          # Next byte should be a 30 (SEQUENCE).
          if [[ "${dercert:0:2}" == "30" ]]; then
               # Get the length of the subjectAltName extension and then skip
               # over the encoding of the length.
               if [[ "${dercert:2:1}" == "8" ]]; then
                    case "${dercert:3:1}" in
                         1) len=2*0x${dercert:4:2}; dercert="${dercert:6}" ;;
                         2) len=2*0x${dercert:4:4}; dercert="${dercert:8}" ;;
                         3) len=2*0x${dercert:4:6}; dercert="${dercert:10}" ;;
                         *) len=0 ;;
                    esac
               else
                    len=2*0x${dercert:2:2}
                    dercert="${dercert:4}"
               fi
               if [[ $len -ne 0 ]] && [[ $len -lt ${#dercert} ]]; then
                    # loop through all the names and extract the SRV-ID and XmppAddr identifiers
                    for (( i=0; i < len; i=i+len_name )); do
                         tag="${dercert:i:2}"
                         i+=2
                         if [[ "${dercert:i:1}" == "8" ]]; then
                              i+=1
                              case "${dercert:i:1}" in
                                   1) i+=1; len_name=2*0x${dercert:i:2}; i+=2 ;;
                                   2) i+=1; len_name=2*0x${dercert:i:4}; i+=4 ;;
                                   3) i+=1; len_name=2*0x${dercert:i:6}; i+=4 ;;
                                   *) len=0 ;;
                              esac
                         else
                              len_name=2*0x${dercert:i:2}
                              i+=2
                         fi
                         if [[ "$tag" == "A0" ]]; then
                              # This is an otherName.
                              if [[ $len_name -gt 18 ]] && ( [[ "${dercert:i:20}" == "06082B06010505070805" ]] || \
                                   [[ "${dercert:i:20}" == "06082B06010505070807" ]] ); then
                                   # According to the OID, this is either an SRV-ID or XmppAddr.
                                   j=$i+20
                                   if [[ "${dercert:j:2}" == "A0" ]]; then
                                        j+=2
                                        if [[ "${dercert:j:1}" == "8" ]]; then
                                             j+=1
                                             j+=2*0x${dercert:j:1}+1
                                        else
                                             j+=2
                                        fi
                                        if ( [[ "${dercert:i:20}" == "06082B06010505070805" ]] && [[ "${dercert:j:2}" == "0C" ]] ) || \
                                           ( [[ "${dercert:i:20}" == "06082B06010505070807" ]] && [[ "${dercert:j:2}" == "16" ]] ); then
                                             # XmppAddr should be encoded as UTF8STRING (0C) and
                                             # SRV-ID should be encoded IA5STRING (16).
                                             j+=2
                                             if [[ "${dercert:j:1}" == "8" ]]; then
                                                  j+=1
                                                  case "${dercert:j:1}" in
                                                       1) j+=1; len1=2*0x${dercert:j:2}; j+=2 ;;
                                                       2) j+=1; len1=2*0x${dercert:j:4}; j+=4 ;;
                                                       3) j+=1; len1=2*0x${dercert:j:6}; j+=6 ;;
                                                       4) len1=0 ;;
                                                  esac
                                             else
                                                  len1=2*0x${dercert:j:2}
                                                  j+=2
                                             fi
                                             if [[ $len1 -ne 0 ]]; then
                                                  san="$(asciihex_to_binary_file "${dercert:j:len1}" "/dev/stdout")"
                                                  if [[ "${dercert:i:20}" == "06082B06010505070805" ]]; then
                                                       xmppaddr+="$san "
                                                  else
                                                       srv_id+="$san "
                                                  fi
                                             fi
                                        fi
                                   fi
                              fi
                         fi
                    done
               fi
          fi
          [[ -n "$srv_id" ]] && HAS_DNS_SANS=true
          [[ -n "$xmppaddr" ]] && HAS_DNS_SANS=true
          while read -d " " san; do
               [[ -n "$san" ]] && [[ $(toupper "$san") == "_XMPP-SERVER.$servername" ]] && subret=1 && break
          done <<< "$srv_id"
          if [[ $subret -eq 0 ]]; then
               while read -d " " san; do
                    [[ -n "$san" ]] && [[ $(toupper "$san") == "$servername" ]] && subret=1 && break
               done <<< "$xmppaddr"
          fi
     fi

     # Check whether any of the DNS names in the certificate are wildcard names
     # that match the servername
     if [[ $subret -eq 0 ]]; then
          while read san; do
               [[ -n "$san" ]] || continue
               wildcard_match "$servername" "$san"
               [[ $? -eq 0 ]] && subret=2 && break
          done <<< "$dns_sans"
     fi

     cn="$(get_cn_from_cert "$cert")"

     # If the CN contains any characters that are not valid for a DNS name,
     # then assume it does not contain a DNS name.
     [[ -n $(sed 's/^[_\.a-zA-Z0-9*\-]*//' <<< "$cn") ]] && return $subret

     # Check whether the CN in the certificate matches the servername
     [[ $(toupper "$cn") == "$servername" ]] && subret+=4 && return $subret

     # Check whether the CN in the certificate is a wildcard name that matches
     # the servername
     wildcard_match "$servername" "$cn"
     [[ $? -eq 0 ]] && subret+=8
     return $subret
}

# This function determines whether the certificate (arg3) contains "visibility
# information" (see Section 4.3.3 of
# https://www.etsi.org/deliver/etsi_ts/103500_103599/10352303/01.01.01_60/ts_10352303v010101p.pdf .
etsi_etls_visibility_info() {
     local jsonID="$1"
     local spaces="$2"
     local cert="$3"
     local cert_txt="$4"
     local dercert tag
     local -a fingerprint=() access_description=()
     local -i i j len len1 len_name nr_visnames=0

     # If "visibility information" is present, it will appear in the subjectAltName
     # extension (0603551D11) as an otherName with OID 0.4.0.3523.3.1 (060604009B430301).
     # OpenSSL displays all names of type otherName as "othername:<unsupported>".
     # As certificates will rarely include a name encoded as an otherName, check the
     # text version of the certificate for "othername:<unsupported>" before calling
     # external functions to obtain the DER encoded certficate.
     if [[ "$cert_txt" =~ X509v3\ Subject\ Alternative\ Name:.*othername:\<unsupported\> ]]; then
          dercert="$($OPENSSL x509 -in "$cert" -outform DER 2>>$ERRFILE | hexdump -v -e '16/1 "%02X"')"
          if [[ "$dercert" =~ 0603551D110101FF04[0-9A-F]*060604009B430301 ]] || \
             [[ "$dercert" =~ 0603551D1104[0-9A-F]*060604009B430301 ]]; then
               # Look for the beginning of the subjectAltName extension. It
               # will begin with the OID (2.5.29.17 = 0603551D11). After the OID
               # there may be an indication that the extension is critical (0101FF).
               # Finally will be the tag indicating that the value of the extension is
               # encoded as an OCTET STRING (04).
               if [[ "$dercert" =~ 0603551D110101FF04 ]]; then
                    dercert="${dercert##*0603551D110101FF04}"
               else
                    dercert="${dercert##*0603551D1104}"
               fi
               # Skip over the encoding of the length of the OCTET STRING.
               if [[ "${dercert:0:1}" == 8 ]]; then
                    i="${dercert:1:1}"
                    i=2*$i+2
                    dercert="${dercert:i}"
               else
                    dercert="${dercert:2}"
               fi
               # Next byte should be a 30 (SEQUENCE).
               if [[ "${dercert:0:2}" == 30 ]]; then
                    # Get the length of the subjectAltName extension and then skip
                    # over the encoding of the length.
                    if [[ "${dercert:2:1}" == 8 ]]; then
                         case "${dercert:3:1}" in
                              1) len=2*0x${dercert:4:2}; dercert="${dercert:6}" ;;
                              2) len=2*0x${dercert:4:4}; dercert="${dercert:8}" ;;
                              3) len=2*0x${dercert:4:6}; dercert="${dercert:10}" ;;
                              *) len=0 ;;
                         esac
                    else
                         len=2*0x${dercert:2:2}
                         dercert="${dercert:4}"
                    fi
                    if [[ $len -ne 0 ]] && [[ $len -lt ${#dercert} ]]; then
                         # loop through all the names and extract the visibility information
                         for (( i=0; i < len; i=i+len_name )); do
                              tag="${dercert:i:2}"
                              i+=2
                              if [[ "${dercert:i:1}" == 8 ]]; then
                                   i+=1
                                   case "${dercert:i:1}" in
                                        1) i+=1; len_name=2*0x${dercert:i:2}; i+=2 ;;
                                        2) i+=1; len_name=2*0x${dercert:i:4}; i+=4 ;;
                                        3) i+=1; len_name=2*0x${dercert:i:6}; i+=4 ;;
                                        *) len=0 ;;
                                   esac
                              else
                                   len_name=2*0x${dercert:i:2}
                                   i+=2
                              fi
                              [[ "$tag" == A0 ]] || continue
                              # This is an otherName.
                              [[ $len_name -gt 16 ]] || continue
                              [[ "${dercert:i:16}" == 060604009B430301 ]] || continue
                              # According to the OID, this is visibility information.
                              j=$i+16
                              # Skip over the tag (A0) and length for the otherName value.
                              [[ "${dercert:j:2}" == A0 ]] || continue
                              j+=2
                              if [[ "${dercert:j:1}" == 8 ]]; then
                                   j+=1
                                   j+=2*0x${dercert:j:1}+1
                              else
                                  j+=2
                              fi
                              # The value for this otherName is encoded as a SEQUENCE (30):
                              #    VisibilityInformation ::= SEQUENCE {
                              #         fingerprint         OCTET STRING (SIZE(10)),
                              #         accessDescription   UTF8String }
                              [[ "${dercert:j:2}" == 30 ]] || continue
                              j+=2
                              if [[ "${dercert:j:1}" == 8 ]]; then
                                   j+=1
                                   case "${dercert:j:1}" in
                                        1) j+=1; len1=2*0x${dercert:j:2}; j+=2 ;;
                                        2) j+=1; len1=2*0x${dercert:j:4}; j+=4 ;;
                                        3) j+=1; len1=2*0x${dercert:j:6}; j+=6 ;;
                                        4) len1=0 ;;
                                   esac
                              else
                                   len1=2*0x${dercert:j:2}
                                   j+=2
                              fi
                              [[ $len1 -ne 0 ]] || continue
                              # Next is the 10-byte fingerprint, encoded as an OCTET STRING (04)
                              [[ "${dercert:j:4}" == 040A ]] || continue
                              j+=4
                              fingerprint[nr_visnames]="$(asciihex_to_binary_file "${dercert:j:20}" "/dev/stdout")"
                              j+=20
                              # Finally comes the access description, encoded as a UTF8String (0C).
                              [[ "${dercert:j:2}" == 0C ]] || continue
                              j+=2
                              if [[ "${dercert:j:1}" == "8" ]]; then
                                   j+=1
                                   case "${dercert:j:1}" in
                                        1) j+=1; len1=2*0x${dercert:j:2}; j+=2 ;;
                                        2) j+=1; len1=2*0x${dercert:j:4}; j+=4 ;;
                                        3) j+=1; len1=2*0x${dercert:j:6}; j+=6 ;;
                                        4) len1=0 ;;
                                   esac
                              else
                                   len1=2*0x${dercert:j:2}
                                   j+=2
                              fi
                              access_description[nr_visnames]=""$(asciihex_to_binary_file "${dercert:j:len1}" "/dev/stdout")""
                              nr_visnames+=1
                         done
                    fi
               fi
          fi
     fi
     if [[ $nr_visnames -eq 0 ]]; then
          outln "not present"
          fileout "$jsonID" "INFO" "not present"
     else
          for (( i=0; i < nr_visnames; i++ )); do
               [[ $i -ne 0 ]] && out "$spaces"
               outln "$(out_row_aligned_max_width "${fingerprint[i]} / ${access_description[i]}" "$spaces" $TERM_WIDTH)"
               fileout "$jsonID" "INFO" "${fingerprint[i]} / ${access_description[i]}"
          done
     fi
     return 0
}

# NOTE: arg3 must contain the text output of $HOSTCERT.
must_staple() {
     local jsonID="cert_mustStapleExtension"
     local json_postfix="$1"
     local provides_stapling="$2"
     local hostcert_txt="$3"
     local cert extn
     local -i extn_len
     local supported=false

     # Note this function is only looking for status_request (5) and not
     # status_request_v2 (17), since OpenSSL seems to only include status_request (5)
     # in its ClientHello when the "-status" option is used.

     # OpenSSL 1.1.0 supports pretty-printing the "TLS Feature extension." For any
     # previous versions of OpenSSL, OpenSSL can only show if the extension OID is present.
     if grep -A 1 "TLS Feature:" <<< "$hostcert_txt" | grep -q "status_request"; then
          # FIXME: This will indicate that must staple is supported if the
          # certificate indicates status_request or status_request_v2. This is
          # probably okay, since it seems likely that any TLS Feature extension
          # that includes status_request_v2 will also include status_request.
          supported=true
     elif [[ "$hostcert_txt" =~ '1.3.6.1.5.5.7.1.24:' ]]; then
          cert="$($OPENSSL x509 -in "$HOSTCERT" -outform DER 2>>$ERRFILE | hexdump -v -e '16/1 "%02X"')"
          extn="${cert##*06082B06010505070118}"
          # Check for critical bit, and skip over it if present.
          [[ "${extn:0:6}" == "0101FF" ]] && extn="${extn:6}"
          # Next is tag and length of extnValue OCTET STRING. Assume it is less than 128 bytes.
          extn="${extn:4}"
          # The TLS Feature is a SEQUENCE of INTEGER. Get the length of the SEQUENCE
          extn_len=2*$(hex2dec "${extn:2:2}")
          # If the extension include the status_request (5), then it supports must staple.
          if [[ "${extn:4:extn_len}" =~ 020105 ]]; then
               supported=true
          fi
     fi

     if "$supported"; then
          if "$provides_stapling"; then
               prln_svrty_good "supported"
               fileout "${jsonID}${json_postfix}" "OK" "supported"
          else
               prln_svrty_high "requires OCSP stapling (NOT ok)"
               fileout "${jsonID}${json_postfix}" "HIGH" "extension detected but no OCSP stapling provided"
          fi
     else
          outln "--"
          fileout "${jsonID}${json_postfix}" "INFO" "--"
     fi
     return 0
}

# TODO: This function checks for Certificate Transparency support based on RFC 6962.
# It will need to be updated to add checks for Certificate Transparency support based on 6962bis.
# return values are results, no error conditions
certificate_transparency() {
     local cert_txt="$1"
     local ocsp_response="$2"
     local -i number_of_certificates=$3
     local cipher="$4"
     local sni_used="$5"
     local tls_version="$6"
     local sni=""
     local ciphers=""
     local hexc n ciph sslver kx auth enc mac export
     local extra_extns=""
     local -i success
     # Cipher suites that use a certifiate with an RSA (signature) public key
     local -r a_rsa="cc,13, cc,15, c0,30, c0,28, c0,14, 00,9f, cc,a8, cc,aa, c0,a3, c0,9f, 00,6b, 00,39, c0,77, 00,c4, 00,88, c0,45, c0,4d, c0,53, c0,61, c0,7d, c0,8b, 16,b7, 16,b9, c0,2f, c0,27, c0,13, 00,9e, c0,a2, c0,9e, 00,67, 00,33, c0,76, 00,be, 00,9a, 00,45, c0,44, c0,4c, c0,52, c0,60, c0,7c, c0,8a, c0,11, c0,12, 00,16, 00,15, 00,14, c0,10"
     # Cipher suites that use a certifiate with an RSA (encryption) public key
     local -r e_rsa="00,b7, c0,99, 00,ad, cc,ae, 00,9d, c0,a1, c0,9d, 00,3d, 00,35, 00,c0, 00,84, 00,95, c0,3d, c0,51, c0,69, c0,6f, c0,7b, c0,93, ff,01, 00,ac, c0,a0, c0,9c, 00,9c, 00,3c, 00,2f, 00,ba, 00,b6, 00,96, 00,41, c0,98, 00,07, 00,94, c0,3c, c0,50, c0,68, c0,6e, c0,7a, c0,92, 00,05, 00,04, 00,92, 00,0a, 00,93, fe,ff, ff,e0, 00,62, 00,09, 00,61, fe,fe, ff,e1, 00,64, 00,60, 00,08, 00,06, 00,03, 00,b9, 00,b8, 00,2e, 00,3b, 00,02, 00,01, ff,00"
     # Cipher suites that use a certifiate with a DSA public key
     local -r a_dss="00,a3, 00,6a, 00,38, 00,c3, 00,87, c0,43, c0,57, c0,81, 00,a2, 00,40, 00,32, 00,bd, 00,99, 00,44, c0,42, c0,56, c0,80, 00,66, 00,13, 00,63, 00,12, 00,65, 00,11"
     # Cipher suites that use a certifiate with a DH public key
     local -r a_dh="00,a5, 00,a1, 00,69, 00,68, 00,37, 00,36, 00,c2, 00,c1, 00,86, 00,85, c0,3f, c0,41, c0,55, c0,59, c0,7f, c0,83, 00,a4, 00,a0, 00,3f, 00,3e, 00,31, 00,30, 00,bc, 00,bb, 00,98, 00,97, 00,43, 00,42, c0,3e, c0,40, c0,54, c0,58, c0,7e, c0,82, 00,10, 00,0d, 00,0f, 00,0c, 00,0b, 00,0e"
     # Cipher suites that use a certifiate with an ECDH public key
     local -r a_ecdh="c0,32, c0,2e, c0,2a, c0,26, c0,0f, c0,05, c0,79, c0,75, c0,4b, c0,4f, c0,5f, c0,63, c0,89, c0,8d, c0,31, c0,2d, c0,29, c0,25, c0,0e, c0,04, c0,78, c0,74, c0,4a, c0,4e, c0,5e, c0,62, c0,88, c0,8c, c0,0c, c0,02, c0,0d, c0,03, c0,0b, c0,01"
     # Cipher suites that use a certifiate with an ECDSA public key
     local -r a_ecdsa="cc,14, c0,2c, c0,24, c0,0a, cc,a9, c0,af, c0,ad, c0,73, c0,49, c0,5d, c0,87, 16,b8, 16,ba, c0,2b, c0,23, c0,09, c0,ae, c0,ac, c0,72, c0,48, c0,5c, c0,86, c0,07, c0,08, c0,06"
     # Cipher suites that use a certifiate with a GOST public key
     local -r a_gost="00,80, 00,81, 00,82, 00,83"

     # First check whether signed certificate timestamps (SCT) are included in the
     # server's certificate. If they aren't, check whether the server provided
     # a stapled OCSP response with SCTs. If no SCTs were found in the certificate
     # or OCSP response, check for an SCT TLS extension.
     if [[ "$cert_txt" =~ CT\ Precertificate\ SCTs ]] || [[ "$cert_txt" =~ '1.3.6.1.4.1.11129.2.4.2' ]]; then
          tm_out "certificate extension"
          return 0
     fi
     if [[ "$ocsp_response" =~ CT\ Certificate\ SCTs ]] || [[ "$ocsp_response" =~ '1.3.6.1.4.1.11129.2.4.5' ]]; then
          tm_out "OCSP extension"
          return 0
     fi

     # If the server only has one certificate, then it is sufficient to check whether
     # determine_tls_extensions() discovered an SCT TLS extension. If the server has more than
     # one certificate, then it is possible that an SCT TLS extension is returned for some
     # certificates, but not for all of them.
     if [[ $number_of_certificates -eq 1 ]] && [[ "$TLS_EXTENSIONS" =~ signed\ certificate\ timestamps ]]; then
          tm_out "TLS extension"
          return 0
     fi

     if [[ $number_of_certificates -gt 1 ]] && ! "$SSL_NATIVE"; then
          if [[ "$tls_version" == 0304 ]]; then
               ciphers=", 13,01, 13,02, 13,03, 13,04, 13,05"
               if [[ "$cipher" == tls1_3_RSA ]]; then
                    extra_extns=", 00,0d,00,10,00,0e,08,04,08,05,08,06,04,01,05,01,06,01,02,01"
               elif [[ "$cipher" == tls1_3_ECDSA ]]; then
                    extra_extns=", 00,0d,00,0a,00,08,04,03,05,03,06,03,02,03"
               else
                    return 1
               fi
          else
               [[ "$cipher" =~ aRSA ]] && ciphers+=", $a_rsa"
               [[ "$cipher" =~ eRSA ]] && ciphers+=", $e_rsa"
               [[ "$cipher" =~ aDSS ]] && ciphers+=", $a_dss"
               [[ "$cipher" =~ aDH ]] && ciphers+=", $a_dh"
               [[ "$cipher" =~ aECDH ]] && ciphers+=", $a_ecdh"
               [[ "$cipher" =~ aECDSA ]] && ciphers+=", $a_ecdsa"
               [[ "$cipher" =~ aGOST ]] && ciphers+=", $a_gost"

               [[ -z "$ciphers" ]] && return 1
               ciphers+=", 00,ff"
          fi
          [[ -z "$sni_used" ]] && sni="$SNI" && SNI=""
          tls_sockets "${tls_version:2:2}" "${ciphers:2}" "all" "00,12,00,00$extra_extns"
          success=$?
          [[ -z "$sni_used" ]] && SNI="$sni"
          if ( [[ $success -eq 0 ]] || [[ $success -eq 2 ]] ) && \
             grep -a 'TLS server extension ' "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" | \
             grep -aq "signed certificate timestamps"; then
               tm_out "TLS extension"
               return 0
          fi
     fi

     if [[ $SERVICE != HTTP ]] && ! "$CLIENT_AUTH"; then
          # At the moment Certificate Transparency only applies to HTTPS.
          tm_out "N/A"
     else
          tm_out "--"
     fi
     return 0
}

certificate_info() {
     local proto
     local -i certificate_number=$1
     local -i number_of_certificates=$2
     local cert_txt="$3"
     local cipher=$4
     local cert_keysize=$5
     local cert_type="$6"
     local ocsp_response_binary="$7"
     local ocsp_response=$8
     local ocsp_response_status=$9
     local sni_used="${10}"
     local ct="${11}"
     local certificate_list_ordering_problem="${12}"
     local cert_sig_algo cert_sig_hash_algo cert_key_algo cert_keyusage cert_ext_keyusage short_keyAlgo
     local outok=true
     local expire days2expire secs2warn ocsp_uri crl
     local startdate enddate issuer_CN issuer_C issuer_O issuer sans san all_san="" cn
     local issuer_DC issuerfinding cn_nosni=""
     local cert_fingerprint_sha1 cert_fingerprint_sha2 cert_serial
     local policy_oid
     local spaces=""
     local -i trust_sni=0 trust_nosni=0 diffseconds=0
     local has_dns_sans has_dns_sans_nosni
     local trust_sni_finding
     local -i certificates_provided
     local cnfinding trustfinding trustfinding_nosni
     local cnok="OK"
     local expfinding expok="OK"
     local -i ret=0
     local json_postfix=""                   # string to place at the end of JSON IDs when there is more than one certificate
     local jsonID=""                         # string to place at beginning of JSON IDs
     local indent=""
     local days2warn2=$DAYS2WARN2
     local days2warn1=$DAYS2WARN1
     local provides_stapling=false
     local caa_node="" all_caa="" caa_property_name="" caa_property_value=""
     local response=""
     local a b c yearstart yearend

     if [[ $number_of_certificates -gt 1 ]]; then
          [[ $certificate_number -eq 1 ]] && outln
          indent="  "
          out "$indent"
          pr_headline "Server Certificate #$certificate_number"
          [[ -z "$sni_used" ]] && pr_underline " (in response to request w/o SNI)"
          outln
          json_postfix=" <cert#${certificate_number}>"
          spaces="                                "
     else
          spaces="                              "
     fi

     GOOD_CA_BUNDLE=""
     cert_sig_algo="$(awk -F':' '/Signature Algorithm/ { print $2; if (++Match >= 1) exit; }' <<< "$cert_txt")"
     cert_sig_algo="${cert_sig_algo// /}"
     cert_key_algo="$(awk -F':' '/Public Key Algorithm:/ { print $2; if (++Match >= 1) exit; }' <<< "$cert_txt")"
     cert_key_algo="${cert_key_algo// /}"

     out "$indent" ; pr_bold " Signature Algorithm          "
     jsonID="cert_signatureAlgorithm"
     case $cert_sig_algo in
          sha1WithRSAEncryption)
               pr_svrty_medium "SHA1 with RSA"
               if [[ "$SERVICE" == HTTP ]] || "$ASSUME_HTTP"; then
                    out " -- besides: users will receive a "; pr_svrty_high "strong browser WARNING"
               fi
               outln
               fileout "${jsonID}${json_postfix}" "MEDIUM" "SHA1 with RSA"
               ;;
          sha224WithRSAEncryption)
               outln "SHA224 with RSA"
               fileout "${jsonID}${json_postfix}" "INFO" "SHA224 with RSA"
               ;;
          sha256WithRSAEncryption)
               prln_svrty_good "SHA256 with RSA"
               fileout "${jsonID}${json_postfix}" "OK" "SHA256 with RSA"
               ;;
          sha384WithRSAEncryption)
               prln_svrty_good "SHA384 with RSA"
               fileout "${jsonID}${json_postfix}" "OK" "SHA384 with RSA"
               ;;
          sha512WithRSAEncryption)
               prln_svrty_good "SHA512 with RSA"
               fileout "${jsonID}${json_postfix}" "OK" "SHA512 with RSA"
               ;;
          ecdsa-with-SHA1)
               prln_svrty_medium "ECDSA with SHA1"
               fileout "${jsonID}${json_postfix}" "MEDIUM" "ECDSA with SHA1"
               ;;
          ecdsa-with-SHA224)
               outln "ECDSA with SHA224"
               fileout "${jsonID}${json_postfix}" "INFO" "ECDSA with SHA224"
               ;;
          ecdsa-with-SHA256)
               prln_svrty_good "ECDSA with SHA256"
               fileout "${jsonID}${json_postfix}" "OK" "ECDSA with SHA256"
               ;;
          ecdsa-with-SHA384)
               prln_svrty_good "ECDSA with SHA384"
               fileout "${jsonID}${json_postfix}" "OK" "ECDSA with SHA384"
               ;;
          ecdsa-with-SHA512)
               prln_svrty_good "ECDSA with SHA512"
               fileout "${jsonID}${json_postfix}" "OK" "ECDSA with SHA512"
               ;;
          dsaWithSHA1)
               prln_svrty_medium "DSA with SHA1"
               fileout "${jsonID}${json_postfix}" "MEDIUM" "DSA with SHA1"
               ;;
          dsa_with_SHA224)
               outln "DSA with SHA224"
               fileout "${jsonID}${json_postfix}" "INFO" "DSA with SHA224"
               ;;
          dsa_with_SHA256)
               prln_svrty_good "DSA with SHA256"
               fileout "${jsonID}${json_postfix}" "OK" "DSA with SHA256"
               ;;
          rsassaPss)
               cert_sig_hash_algo="$(grep -A 1 "Signature Algorithm" <<< "$cert_txt" | head -2 | tail -1 | sed 's/^.*Hash Algorithm: //')"
               case $cert_sig_hash_algo in
                    sha1)
                         prln_svrty_medium "RSASSA-PSS with SHA1"
                         fileout "${jsonID}${json_postfix}" "MEDIUM" "RSASSA-PSS with SHA1"
                         ;;
                    sha224)
                         outln "RSASSA-PSS with SHA224"
                         fileout "${jsonID}${json_postfix}" "INFO" "RSASSA-PSS with SHA224"
                         ;;
                    sha256)
                         prln_svrty_good "RSASSA-PSS with SHA256"
                         fileout "${jsonID}${json_postfix}" "OK" "RSASSA-PSS with SHA256"
                         ;;
                    sha384)
                         prln_svrty_good "RSASSA-PSS with SHA384"
                         fileout "${jsonID}${json_postfix}" "OK" "RSASSA-PSS with SHA384"
                         ;;
                    sha512)
                         prln_svrty_good "RSASSA-PSS with SHA512"
                         fileout "${jsonID}${json_postfix}" "OK" "RSASSA-PSS with SHA512"
                         ;;
                    *)
                         out "RSASSA-PSS with $cert_sig_hash_algo"
                         prln_warning " (Unknown hash algorithm)"
                         fileout "${jsonID}${json_postfix}" "DEBUG" "RSASSA-PSS with $cert_sig_hash_algo"
                    esac
                    ;;
          md2*)
               prln_svrty_critical "MD2"
               fileout "${jsonID}${json_postfix}" "CRITICAL" "MD2"
               ;;
          md4*)
               prln_svrty_critical "MD4"
               fileout "${jsonID}${json_postfix}" "CRITICAL" "MD4"
               ;;
          md5*)
               prln_svrty_critical "MD5"
               fileout "${jsonID}${json_postfix}" "CRITICAL" "MD5"
               ;;
          *)
               out "$cert_sig_algo ("
               pr_warning "FIXME: can't tell whether this is good or not"
               outln ")"
               fileout "${jsonID}${json_postfix}" "DEBUG" "$cert_sig_algo"
               ((ret++))
               ;;
     esac
     # old, but still interesting: https://blog.hboeck.de/archives/754-Playing-with-the-EFF-SSL-Observatory.html

     out "$indent"; pr_bold " Server key size              "
     jsonID="cert_keySize"
     if [[ -z "$cert_keysize" ]]; then
          outln "(couldn't determine)"
          fileout "${jsonID}${json_postfix}" "cannot be determined"
          ((ret++))
     else
          case $cert_key_algo in
               *RSA*|*rsa*)             short_keyAlgo="RSA";;
               *ecdsa*|*ecPublicKey)    short_keyAlgo="EC";;
               *DSA*|*dsa*)             short_keyAlgo="DSA";;
               *GOST*|*gost*)           short_keyAlgo="GOST";;
               *dh*|*DH*)               short_keyAlgo="DH" ;;
               *)                       pr_fixme "don't know $cert_key_algo "
                                        let ret++ ;;
          esac
          out "$short_keyAlgo "
          # https://tools.ietf.org/html/rfc4492,  http://www.keylength.com/en/compare/
          # http://infoscience.epfl.ch/record/164526/files/NPDF-22.pdf
          # see http://csrc.nist.gov/publications/nistpubs/800-57/sp800-57_part1_rev3_general.pdf
          # Table 2 @ chapter 5.6.1 (~ p64)
          if [[ $cert_key_algo =~ ecdsa ]] || [[ $cert_key_algo =~ ecPublicKey ]]; then
               if [[ "$cert_keysize" -le 110 ]]; then       # a guess
                    pr_svrty_critical "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "CRITICAL" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 123 ]]; then     # a guess
                    pr_svrty_high "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "HIGH" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 163 ]]; then
                    pr_svrty_medium "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "MEDIUM" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 224 ]]; then
                    out "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "INFO" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 533 ]]; then
                    pr_svrty_good "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "OK" "$short_keyAlgo $cert_keysize bits"
               else
                    out "keysize: $cert_keysize (not expected, FIXME)"
                    fileout "${jsonID}${json_postfix}" "DEBUG" " $cert_keysize bits (not expected)"
                    ((ret++))
               fi
               outln " bits"
          elif [[ $cert_key_algo =~ RSA ]] || [[ $cert_key_algo =~ rsa ]] || [[ $cert_key_algo =~ dsa ]] || \
               [[ $cert_key_algo =~ dhKeyAgreement ]] || [[ $cert_key_algo == X9.42\ DH ]]; then
               if [[ "$cert_keysize" -le 512 ]]; then
                    pr_svrty_critical "$cert_keysize"
                    outln " bits"
                    fileout "${jsonID}${json_postfix}" "CRITICAL" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 768 ]]; then
                    pr_svrty_high "$cert_keysize"
                    outln " bits"
                    fileout "${jsonID}${json_postfix}" "HIGH" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 1024 ]]; then
                    pr_svrty_medium "$cert_keysize"
                    outln " bits"
                    fileout "${jsonID}${json_postfix}" "MEDIUM" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 2048 ]]; then
                    outln "$cert_keysize bits"
                    fileout "${jsonID}${json_postfix}" "INFO" "$short_keyAlgo $cert_keysize bits"
               elif [[ "$cert_keysize" -le 4096 ]]; then
                    pr_svrty_good "$cert_keysize"
                    fileout "${jsonID}${json_postfix}" "OK" "$short_keyAlgo $cert_keysize bits"
                    outln " bits"
               else
                    pr_warning "weird key size: $cert_keysize bits"; outln " (could cause compatibility problems)"
                    fileout "${jsonID}${json_postfix}" "WARN" "$cert_keysize bits (Odd)"
                    ((ret++))
               fi
          else
               out "$cert_key_algo + $cert_keysize bits ("
               pr_warning "FIXME: can't tell whether this is good or not"
               outln ")"
               fileout "${jsonID}${json_postfix}" "WARN" "Server keys $cert_keysize bits, unknown public key algorithm $cert_key_algo"
               ((ret++))
          fi
     fi

     out "$indent"; pr_bold " Server key usage             ";
     outok=true
     jsonID="cert_keyUsage"
     cert_keyusage="$(strip_leading_space "$(awk '/X509v3 Key Usage:/ { getline; print $0 }' <<< "$cert_txt")")"
     if [[ -n "$cert_keyusage" ]]; then
          outln "$cert_keyusage"
          if ( [[ " $cert_type " =~ " RSASig " ]] || [[ " $cert_type " =~ " DSA " ]] || [[ " $cert_type " =~ " ECDSA " ]] ) && \
             [[ ! "$cert_keyusage" =~ "Digital Signature" ]]; then
               prln_svrty_high "$indent                              Certificate incorrectly used for digital signatures"
               fileout "${jsonID}${json_postfix}" "HIGH" "Certificate incorrectly used for digital signatures: \"$cert_keyusage\""
               outok=false
          fi
          if [[ " $cert_type " =~ " RSAKMK " ]] && [[ ! "$cert_keyusage" =~ "Key Encipherment" ]]; then
               prln_svrty_high "$indent                              Certificate incorrectly used for key encipherment"
               fileout "${jsonID}${json_postfix}" "HIGH" "Certificate incorrectly used for key encipherment: \"$cert_keyusage\""
               outok=false
          fi
          if ( [[ " $cert_type " =~ " DH " ]] || [[ " $cert_type " =~ " ECDH " ]] ) && \
             [[ ! "$cert_keyusage" =~ "Key Agreement" ]]; then
               prln_svrty_high "$indent                              Certificate incorrectly used for key agreement"
               fileout "${jsonID}${json_postfix}" "HIGH" "Certificate incorrectly used for key agreement: \"$cert_keyusage\""
               outok=false
          fi
     else
          outln "--"
          fileout "${jsonID}${json_postfix}" "INFO" "No server key usage information"
          outok=false
     fi
     if "$outok"; then
          fileout "${jsonID}${json_postfix}" "INFO" "$cert_keyusage"
     fi

     out "$indent"; pr_bold " Server extended key usage    ";
     jsonID="cert_extKeyUsage"
     outok=true
     cert_ext_keyusage="$(strip_leading_space "$(awk '/X509v3 Extended Key Usage:/ { getline; print $0 }' <<< "$cert_txt")")"
     if [[ -n "$cert_ext_keyusage" ]]; then
          outln "$cert_ext_keyusage"
          if [[ ! "$cert_ext_keyusage" =~ "TLS Web Server Authentication" ]] && [[ ! "$cert_ext_keyusage" =~ "Any Extended Key Usage" ]]; then
               prln_svrty_high "$indent                              Certificate incorrectly used for TLS Web Server Authentication"
               fileout "${jsonID}${json_postfix}" "HIGH" "Certificate incorrectly used for TLS Web Server Authentication: \"$cert_ext_keyusage\""
               outok=false
          fi
     else
          outln "--"
          fileout "${jsonID}${json_postfix}" "INFO" "No server extended key usage information"
          outok=false
     fi
     if "$outok"; then
          fileout "${jsonID}${json_postfix}" "INFO" "cert_ext_keyusage"
     fi

     out "$indent"; pr_bold " Serial / Fingerprints        "
     cert_serial="$($OPENSSL x509 -noout -in $HOSTCERT -serial 2>>$ERRFILE | sed 's/serial=//')"
     fileout "cert_serialNumber${json_postfix}" "INFO" "$cert_serial"

     cert_fingerprint_sha1="$($OPENSSL x509 -noout -in $HOSTCERT -fingerprint -sha1 2>>$ERRFILE | sed 's/Fingerprint=//' | sed 's/://g')"
     fileout "cert_fingerprintSHA1${json_postfix}" "INFO" "${cert_fingerprint_sha1//SHA1 /}"
     outln "$cert_serial / $cert_fingerprint_sha1"

     cert_fingerprint_sha2="$($OPENSSL x509 -noout -in $HOSTCERT -fingerprint -sha256 2>>$ERRFILE | sed 's/Fingerprint=//' | sed 's/://g' )"
     fileout "cert_fingerprintSHA256${json_postfix}" "INFO" "${cert_fingerprint_sha2//SHA256 /}"
     outln "$spaces$cert_fingerprint_sha2"

     # " " needs to be converted back to lf in JSON/CSV output
     fileout "cert${json_postfix}" "INFO" "$(< $HOSTCERT)"

     [[ -z $CERT_FINGERPRINT_SHA2 ]] && \
          CERT_FINGERPRINT_SHA2="$cert_fingerprint_sha2" ||
          CERT_FINGERPRINT_SHA2="$cert_fingerprint_sha2 $CERT_FINGERPRINT_SHA2"
     [[ -z $RSA_CERT_FINGERPRINT_SHA2 ]] && \
          ( [[ $cert_key_algo = *RSA* ]] || [[ $cert_key_algo = *rsa* ]] ) &&
          RSA_CERT_FINGERPRINT_SHA2="$cert_fingerprint_sha2"

     out "$indent"; pr_bold " Common Name (CN)             "
     cnfinding="Common Name (CN) : "
     cn="$(get_cn_from_cert $HOSTCERT)"
     if [[ -n "$cn" ]]; then
          pr_italic "$cn"
          cnfinding="$cn"
     else
          cn="no CN field in subject"
          out "($cn)"
          cnfinding="$cn"
          cnok="INFO"
     fi
     fileout "cert_commonName${json_postfix}" "$cnok" "$cnfinding"
     cnfinding=""

     if [[ -n "$sni_used" ]]; then
          if grep -q "\-\-\-\-\-BEGIN" "$HOSTCERT.nosni"; then
               cn_nosni="$(get_cn_from_cert "$HOSTCERT.nosni")"
               [[ -z "$cn_nosni" ]] && cn_nosni="no CN field in subject"
          fi
          debugme tm_out "\"$NODE\" | \"$cn\" | \"$cn_nosni\""
     else
          debugme tm_out "\"$NODE\" | \"$cn\""
     fi

     if [[ -z "$sni_used" ]] || [[ "$(toupper "$cn_nosni")" == "$(toupper "$cn")" ]]; then
          outln
          cnfinding="$cn"
     elif [[ -z "$cn_nosni" ]]; then
          out " (request w/o SNI didn't succeed";
          cnfinding+="request w/o SNI didn't succeed"
          if [[ $cert_sig_algo =~ ecdsa ]]; then
               out ", usual for EC certificates"
               cnfinding+=", usual for EC certificates"
          fi
          outln ")"
          cnfinding+=""
     elif [[ "$cn_nosni" == *"no CN field"* ]]; then
          outln ", (request w/o SNI: $cn_nosni)"
          cnfinding="$cn_nosni"
     else
          out " (CN in response to request w/o SNI: "; pr_italic "$cn_nosni"; outln ")"
          cnfinding="$cn_nosni"
     fi
     fileout "cert_commonName_wo_SNI${json_postfix}" "INFO" "$cnfinding"

     sans=$(grep -A2 "Subject Alternative Name" <<< "$cert_txt" | \
          grep -E "DNS:|IP Address:|email:|URI:|DirName:|Registered ID:" | tr ',' '\n' | \
          sed -e 's/ *DNS://g' -e 's/ *IP Address://g' -e 's/ *email://g' -e 's/ *URI://g' -e 's/ *DirName://g' \
              -e 's/ *Registered ID://g' \
              -e 's/ *othername:<unsupported>//g' -e 's/ *X400Name:<unsupported>//g' -e 's/ *EdiPartyName:<unsupported>//g')
          #           ^^^ CACert

     out "$indent"; pr_bold " subjectAltName (SAN)         "
     jsonID="cert_subjectAltName"
     if [[ -n "$sans" ]]; then
          while read san; do
               [[ -n "$san" ]] && all_san+="$san "
          done <<< "$sans"
          prln_italic "$(out_row_aligned_max_width "$all_san" "$indent                              " $TERM_WIDTH)"
          fileout "${jsonID}${json_postfix}" "INFO" "$all_san"
     else
          if [[ $SERVICE == "HTTP" ]] || "$ASSUME_HTTP"; then
               pr_svrty_high "missing (NOT ok)"; outln " -- Browsers are complaining"
               fileout "${jsonID}${json_postfix}" "HIGH" "No SAN, browsers are complaining"
          else
               pr_svrty_medium "missing"; outln " -- no SAN is deprecated"
               fileout "${jsonID}${json_postfix}" "MEDIUM" "Providing no SAN is deprecated"
          fi
     fi

     out "$indent"; pr_bold " Issuer                       "
     jsonID="cert_caIssuers"
     #FIXME: oid would be better maybe (see above)
     issuer="$($OPENSSL x509 -in  $HOSTCERT -noout -issuer -nameopt multiline,-align,sname,-esc_msb,utf8,-space_eq 2>>$ERRFILE)"
     issuer_CN="$(awk -F'=' '/CN=/ { print $2 }' <<< "$issuer")"
     issuer_O="$(awk -F'=' '/O=/ { print $2 }' <<< "$issuer")"
     issuer_C="$(awk -F'=' '/ C=/ { print $2 }' <<< "$issuer")"
     issuer_DC="$(awk -F'=' '/DC=/ { print $2 }' <<< "$issuer")"

     if [[ "$issuer_O" == "issuer=" ]] || [[ "$issuer_O" == "issuer= " ]] || [[ "$issuer_CN" == "$cn" ]]; then
          prln_svrty_critical "self-signed (NOT ok)"
          fileout "${jsonID}${json_postfix}" "CRITICAL" "selfsigned"
     else
          issuerfinding="$issuer_CN"
          pr_italic "$issuer_CN"
          if [[ -z "$issuer_O" ]] && [[ -n "$issuer_DC" ]]; then
               for san in $issuer_DC; do
                    if [[ -z "$issuer_O" ]]; then
                         issuer_O="${san}"
                    else
                         issuer_O="${san}.${issuer_O}"
                    fi
               done
          fi
          if [[ -n "$issuer_O" ]]; then
               issuerfinding+=" ("
               out " ("
               issuerfinding+="$issuer_O"
               pr_italic "$issuer_O"
               if [[ -n "$issuer_C" ]]; then
                    issuerfinding+=" from "
                    out " from "
                    issuerfinding+="$issuer_C"
                    pr_italic "$issuer_C"
               fi
               issuerfinding+=")"
               out ")"
          fi
          outln
          fileout "${jsonID}${json_postfix}" "INFO" "$issuerfinding"
     fi

     out "$indent"; pr_bold " Trust (hostname)             "
     compare_server_name_to_cert "$HOSTCERT"
     trust_sni=$?

     # Find out if the subjectAltName extension is present and contains
     # a DNS name, since Section 6.3 of RFC 6125 says:
     #      Security Warning: A client MUST NOT seek a match for a reference
     #      identifier of CN-ID if the presented identifiers include a DNS-ID,
     #      SRV-ID, URI-ID, or any application-specific identifier types
     #      supported by the client.
     has_dns_sans=$HAS_DNS_SANS

     case $trust_sni in
          0) trustfinding="certificate does not match supplied URI" ;;
          1) trustfinding="Ok via SAN" ;;
          2) trustfinding="Ok via SAN wildcard" ;;
          4) if "$has_dns_sans"; then
                  trustfinding="via CN, but not SAN"
             else
                  trustfinding="via CN only"
             fi
             ;;
          5) trustfinding="Ok via SAN and CN" ;;
          6) trustfinding="Ok via SAN wildcard and CN"
             ;;
          8) if "$has_dns_sans"; then
                  trustfinding="via CN wildcard, but not SAN"
             else
                  trustfinding="via CN (wildcard) only"
             fi
             ;;
          9) trustfinding="Ok via CN wildcard and SAN"
             ;;
         10) trustfinding="Ok via SAN wildcard and CN wildcard"
             ;;
     esac

     if [[ $trust_sni -eq 0 ]]; then
          pr_svrty_high "$trustfinding"
          trust_sni_finding="HIGH"
     elif ( [[ $trust_sni -eq 4 ]] || [[ $trust_sni -eq 8 ]] ); then
          if [[ $SERVICE == "HTTP" ]] || "$ASSUME_HTTP"; then
               # https://bugs.chromium.org/p/chromium/issues/detail?id=308330
               # https://bugzilla.mozilla.org/show_bug.cgi?id=1245280
               # https://www.chromestatus.com/feature/4981025180483584
               pr_svrty_high "$trustfinding"; out " -- Browsers are complaining"
               trust_sni_finding="HIGH"
          else
               pr_svrty_medium "$trustfinding"
               trust_sni_finding="MEDIUM"
               # we punish CN matching for non-HTTP as it is deprecated https://tools.ietf.org/html/rfc2818#section-3.1
               ! "$has_dns_sans" && out " -- CN only match is deprecated"
          fi
     else
          pr_svrty_good "$trustfinding"
          trust_sni_finding="OK"
     fi

     if [[ -n "$cn_nosni" ]]; then
          compare_server_name_to_cert "$HOSTCERT.nosni"
          trust_nosni=$?
          has_dns_sans_nosni=$HAS_DNS_SANS
     fi

     # See issue #733.
     if [[ -z "$sni_used" ]]; then
          trustfinding_nosni=""
     elif ( [[ $trust_sni -eq $trust_nosni ]] && [[ "$has_dns_sans" == "$has_dns_sans_nosni" ]] ) || \
          ( [[ $trust_sni -eq 0 ]] && [[ $trust_nosni -eq 0 ]] ); then
          trustfinding_nosni=" (same w/o SNI)"
     elif [[ $trust_nosni -eq 0 ]]; then
          if [[ $trust_sni -eq 4 ]] || [[ $trust_sni -eq 8 ]]; then
               trustfinding_nosni=" (w/o SNI: certificate does not match supplied URI)"
          else
               trustfinding_nosni=" (SNI mandatory)"
          fi
     elif [[ $trust_nosni -eq 4 ]] || [[ $trust_nosni -eq 8 ]] || [[ $trust_sni -eq 4 ]] || [[ $trust_sni -eq 8 ]]; then
          case $trust_nosni in
               1) trustfinding_nosni="(w/o SNI: Ok via SAN)" ;;
               2) trustfinding_nosni="(w/o SNI: Ok via SAN wildcard)" ;;
               4) if "$has_dns_sans_nosni"; then
                       trustfinding_nosni="(w/o SNI: via CN, but not SAN)"
                  else
                       trustfinding_nosni="(w/o SNI: via CN only)"
                  fi
                  ;;
               5) trustfinding_nosni="(w/o SNI: Ok via SAN and CN)" ;;
               6) trustfinding_nosni="(w/o SNI: Ok via SAN wildcard and CN)" ;;
               8) if "$has_dns_sans_nosni"; then
                       trustfinding_nosni="(w/o SNI: via CN wildcard, but not SAN)"
                  else
                       trustfinding_nosni="(w/o SNI: via CN (wildcard) only)"
                  fi
                  ;;
               9) trustfinding_nosni="(w/o SNI: Ok via CN wildcard and SAN)" ;;
              10) trustfinding_nosni="(w/o SNI: Ok via SAN wildcard and CN wildcard)" ;;
          esac
     elif [[ $trust_sni -ne 0 ]]; then
          trustfinding_nosni=" (works w/o SNI)"
     else
          trustfinding_nosni=" (however, works w/o SNI)"
     fi
     if [[ -n "$sni_used" ]] || [[ $trust_nosni -eq 0 ]] || ( [[ $trust_nosni -ne 4 ]] && [[ $trust_nosni -ne 8 ]] ); then
          outln "$trustfinding_nosni"
     elif [[ $SERVICE == "HTTP" ]] || "$ASSUME_HTTP"; then
          prln_svrty_high "$trustfinding_nosni"
     else
          prln_svrty_medium "$trustfinding_nosni"
     fi

     fileout "cert_trust${json_postfix}" "$trust_sni_finding" "${trustfinding}${trustfinding_nosni}"

     out "$indent"; pr_bold " Chain of trust"; out "               "
     jsonID="cert_chain_of_trust"
     if [[ "$issuer_O" =~ StartCom ]] || [[ "$issuer_O" =~ WoSign ]] || [[ "$issuer_CN" =~ StartCom ]] || [[ "$issuer_CN" =~ WoSign ]]; then
          # Shortcut for this special case here.
          pr_italic "WoSign/StartCom"; out " are " ; prln_svrty_critical "not trusted anymore (NOT ok)"
          fileout "${jsonID}${json_postfix}" "CRITICAL" "Issuer not trusted anymore (WoSign/StartCom)"
     else
          # Also handles fileout, keep error if happened
          determine_trust "$jsonID" "$json_postfix" || ((ret++))
     fi

     # http://events.ccc.de/congress/2010/Fahrplan/attachments/1777_is-the-SSLiverse-a-safe-place.pdf, see page 40pp
     out "$indent"; pr_bold " EV cert"; out " (experimental)       "
     jsonID="cert_certificatePolicies_EV"
     # only the first one, seldom we have two
     policy_oid=$(awk '/ .Policy: / { print $2 }' <<< "$cert_txt" | awk 'NR < 2')
     if grep -Eq 'Extended Validation|Extended Validated|EV SSL|EV CA' <<< "$issuer" || \
          [[ 2.16.840.1.114028.10.1.2 == "$policy_oid" ]] || \
          [[ 2.16.840.1.114412.1.3.0.2 == "$policy_oid" ]] || \
          [[ 2.16.840.1.114412.2.1 == "$policy_oid" ]] || \
          [[ 2.16.578.1.26.1.3.3 == "$policy_oid" ]] || \
          [[ 1.3.6.1.4.1.17326.10.14.2.1.2 == "$policy_oid" ]] || \
          [[ 1.3.6.1.4.1.17326.10.8.12.1.2 == "$policy_oid" ]] || \
          [[ 1.3.6.1.4.1.13177.10.1.3.10 == "$policy_oid" ]] ; then
          out "yes "
          fileout "${jsonID}${json_postfix}" "OK" "yes"
     else
          out "no "
          fileout "${jsonID}${json_postfix}" "INFO" "no"
     fi
     debugme echo "($(newline_to_spaces "$policy_oid"))"
     outln
#TODO: check browser OIDs:
#         https://mxr.mozilla.org/mozilla-central/source/security/certverifier/ExtendedValidation.cpp
#         http://src.chromium.org/chrome/trunk/src/net/cert/ev_root_ca_metadata.cc
#         https://certs.opera.com/03/ev-oids.xml
#         see #967

     out "$indent"; pr_bold " ETS/\"eTLS\""
     out ", visibility info  "
     jsonID="cert_eTLS"
     etsi_etls_visibility_info "$jsonID" "$spaces" "$HOSTCERT" "$cert_txt"
     # *Currently* this is even listed as a vulnerability (CWE-310, CVE-2019-919), see
     # https://nvd.nist.gov/vuln/detail/CVE-2019-9191, https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-9191
     # For now we leave this here. We may want to change that later or add infos to other sections (PFS & vulnerability)

     out "$indent"; pr_bold " Certificate Validity (UTC)   "

     # FreeBSD + OSX can't swallow the leading blank:
     enddate="${cert_txt#*Validity*Not Before: *Not After : }"
     enddate="${enddate%%GMT*}GMT"
     startdate="${cert_txt#*Validity*Not Before: }"
     startdate="${startdate%%GMT*}GMT"
     # Now we have a normalized enddate and startdate like "Feb 27 10:03:20 2017 GMT" -- also for OpenBSD
     debugme echo "$enddate - $startdate"
     # In all OS except OpenBSD it'll be reduced to "2017-02-27 11:03"
     enddate="$(parse_date "$enddate" +"%F %H:%M" "%b %d %T %Y %Z")"
     startdate="$(parse_date "$startdate" +"%F %H:%M" "%b %d %T %Y %Z")"

     if "$HAS_OPENBSDDATE"; then
          # best we are able to do under OpenBSD
          days2expire=""
          read a b c yearstart tz  <<< "$startdate"
          read a b c yearend tz  <<< "$enddate"
          # we only take the year here as OpenBSD's date is not for conversion
          diffseconds=$((yearend - yearstart))
          diffseconds=$((diffseconds * 3600 * 24 * 365))
     else
          days2expire=$(( $(parse_date "$enddate" "+%s" $'%F %H:%M') - $(LC_ALL=C date "+%s") ))  # first in seconds
          days2expire=$((days2expire  / 3600 / 24 ))
          # we adjust the thresholds by %50 for LE certificates, relaxing those warnings
          # . instead of \' because it does not break syntax highlighting in vim
          if [[ "$issuer_CN" =~ ^Let.s\ Encrypt\ Authority ]] ; then
                 days2warn2=$((days2warn2 / 2))
                 days2warn1=$((days2warn1 / 2))
          fi
          diffseconds=$(( $(parse_date "$enddate" "+%s" $'%F %H:%M') - $(parse_date "$startdate" "+%s" $'%F %H:%M') ))
     fi
     debugme echo -n "diffseconds: $diffseconds"
     expire=$($OPENSSL x509 -in $HOSTCERT -checkend 1 2>>$ERRFILE)
     if ! grep -qw not <<< "$expire" ; then
          pr_svrty_critical "expired"
          expfinding="expired"
          expok="CRITICAL"
     else
          secs2warn=$((24 * 60 * 60 * days2warn2))          # low threshold first
          expire=$($OPENSSL x509 -in $HOSTCERT -checkend $secs2warn 2>>$ERRFILE)
          if grep -qw not <<< "$expire"; then
               secs2warn=$((24 * 60 * 60 * days2warn1))     # high threshold
               expire=$($OPENSSL x509 -in $HOSTCERT -checkend $secs2warn 2>>$ERRFILE)
               if grep -qw not <<< "$expire"; then
                    pr_svrty_good "$days2expire >= $days2warn1 days"
                    expfinding+="$days2expire >= $days2warn1 days"
               else
                    pr_svrty_medium "expires < $days2warn1 days ($days2expire)"
                    expfinding+="expires < $days2warn1 days ($days2expire)"
                    expok="MEDIUM"
               fi
          else
               pr_svrty_high "expires < $days2warn2 days ($days2expire)"
               expfinding+="expires < $days2warn2 days ($days2expire)"
               expok="HIGH"
          fi
     fi
     outln " ($startdate --> $enddate)"
     fileout "cert_expirationStatus${json_postfix}" "$expok" "$expfinding"
     fileout "cert_notBefore${json_postfix}" "INFO" "$startdate"      # we assume that the certificate has no start time in the future
     fileout "cert_notAfter${json_postfix}" "$expok" "$enddate"       # They are in UTC

     if [[ $diffseconds -ge $((3600 * 24 * 365 * 10)) ]]; then
          # certificate is valid >= 10 years
          out "$spaces"
          prln_svrty_high ">= 10 years is way too long"
          fileout "cert_validityPeriod${json_postfix}" "HIGH" "$((diffseconds / 3600 * 24 )) days"
     elif [[ $diffseconds -ge $((3600 * 24 * 365 * 5)) ]]; then
          out "$spaces"
          prln_svrty_medium ">= 5 years is too long"
          fileout "cert_validityPeriod${json_postfix}" "MEDIUM" "$((diffseconds / 3600 * 24 )) days"
     else
          [[ "$DEBUG" -ge 1 ]] && outln "${spaces}OK: below 5 years certificate life time"
          fileout "cert_validityPeriod${json_postfix}" "INFO" "$((diffseconds / 3600 * 24 )) days"
     fi

     certificates_provided=1+$(grep -c "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TEMPDIR/intermediatecerts.pem)
     out "$indent"; pr_bold " # of certificates provided"; out "   $certificates_provided"
     fileout "certs_countServer${json_postfix}" "INFO" "${certificates_provided}"
     if "$certificate_list_ordering_problem"; then
          prln_svrty_low " (certificate list ordering problem)"
          fileout "certs_list_ordering_problem${json_postfix}" "LOW" "yes"
     else
          fileout "certs_list_ordering_problem${json_postfix}" "INFO" "no"
          outln
     fi

     if "$PHONE_OUT"; then
          out "$indent"; pr_bold " In pwnedkeys.com DB          "
          check_pwnedkeys "$HOSTCERT" "$cert_key_algo" "$cert_keysize"
          case "$?" in
               0) outln "not checked"; fileout "pwnedkeys${json_postfix}" "INFO" "not checked" ;;
               1) outln "not in database"; fileout "pwnedkeys${json_postfix}" "INFO" "not in database" ;;
               2) pr_svrty_critical "NOT ok --"; outln " key appears in database"; fileout "pwnedkeys${json_postfix}" "CRITICAL" "private key is known" ;;
               7) prln_warning "error querying https://v1.pwnedkeys.com"; fileout "pwnedkeys${json_postfix}" "WARN" "connection error" ;;
          esac
     fi

     out "$indent"; pr_bold " Certificate Revocation List  "
     jsonID="cert_crlDistributionPoints"
     # ~ get next 50 lines after pattern , strip until Signature Algorithm and retrieve URIs
     crl="$(awk '/X509v3 CRL Distribution/{i=50} i&&i--' <<< "$cert_txt" | awk '/^$/,/^            [a-zA-Z0-9]+|^    Signature Algorithm:/' | awk -F'URI:' '/URI/ { print $2 }')"
     if [[ -z "$crl" ]] ; then
          fileout "${jsonID}${json_postfix}" "INFO" "--"
          outln "--"
     else
          if [[ $(count_lines "$crl") -eq 1 ]]; then
               out "$crl"
               if [[ "$expfinding" != "expired" ]]; then
                    check_revocation_crl "$crl" "cert_crlRevoked${json_postfix}"
                    ret=$((ret +$?))
               fi
               outln
          else # more than one CRL
               first_crl=true
               while read -r line; do
                    if "$first_crl"; then
                         first_crl=false
                    else
                         out "$spaces"
                    fi
                    out "$line"
                    if [[ "$expfinding" != expired ]]; then
                         check_revocation_crl "$line" "cert_crlRevoked${json_postfix}"
                         ret=$((ret +$?))
                    fi
                    outln
               done <<< "$crl"
          fi
          fileout "${jsonID}${json_postfix}" "INFO" "$crl"
     fi

     out "$indent"; pr_bold " OCSP URI                     "
     jsonID="cert_ocspURL"
     ocsp_uri=$($OPENSSL x509 -in $HOSTCERT -noout -ocsp_uri 2>>$ERRFILE)
     if [[ -z "$ocsp_uri" ]]; then
          outln "--"
          fileout "${jsonID}${json_postfix}" "INFO" "--"
     else
          if [[ $(count_lines "$ocsp_uri") -eq 1 ]]; then
               out "$ocsp_uri"
               if [[ "$expfinding" != "expired" ]]; then
                    check_revocation_ocsp "$ocsp_uri" "" "cert_ocspRevoked${json_postfix}"
               fi
               ret=$((ret +$?))
               outln
          else
               first_ocsp=true
               while read -r line; do
                    if "$first_ocsp"; then
                         first_ocsp=false
                    else
                         out "$spaces"
                    fi
                    out "$line"
                    if [[ "$expfinding" != "expired" ]]; then
                         check_revocation_ocsp "$line" "" "cert_ocspRevoked${json_postfix}"
                         ret=$((ret +$?))
                    fi
                    outln
               done <<< "$ocsp_uri"
          fi
          fileout "${jsonID}${json_postfix}" "INFO" "$ocsp_uri"
     fi
     if [[ -z "$ocsp_uri" ]] && [[ -z "$crl" ]]; then
          out "$spaces"
          pr_svrty_high "NOT ok --"
          outln " neither CRL nor OCSP URI provided"
          fileout "cert_revocation${json_postfix}" "HIGH" "Neither CRL nor OCSP URI provided"
     fi

     out "$indent"; pr_bold " OCSP stapling                "
     jsonID="OCSP_stapling"
     if grep -a "OCSP response" <<< "$ocsp_response" | grep -q "no response sent" ; then
          if [[ -n "$ocsp_uri" ]]; then
               pr_svrty_low "not offered"
               fileout "${jsonID}${json_postfix}" "LOW" "not offered"
          else
               out "not offered"
               fileout "${jsonID}${json_postfix}" "INFO" "not offered"
          fi
     else
          if grep -a "OCSP Response Status" <<< "$ocsp_response_status" | grep -q successful; then
               pr_svrty_good "offered"
               fileout "${jsonID}${json_postfix}" "OK" "offered"
               provides_stapling=true
               check_revocation_ocsp "" "$ocsp_response_binary" "cert_ocspRevoked${json_postfix}"
          elif [[ "$ocsp_response" =~ Responder\ Error: ]]; then
               response="$(awk '/Responder Error:/ { print $3 }' <<< "$ocsp_response")"
               pr_warning "stapled OCSP response contained an error response from OCSP responder: $response"
               fileout "${jsonID}${json_postfix}" "WARN" "stapled OCSP response contained an error response from OCSP responder: $response"
          else
               if $GOST_STATUS_PROBLEM; then
                    pr_warning "(GOST servers make problems here, sorry)"
                    fileout "${jsonID}${json_postfix}" "WARN" "(The GOST server made a problem here, sorry)"
                    ((ret++))
               else
                    out "(response status unknown)"
                    fileout "${jsonID}${json_postfix}" "OK" " not sure what's going on here, '$ocsp_response'"
                    debugme grep -a -A20 -B2 "OCSP response"  <<<"$ocsp_response"
                    ((ret++))
               fi
          fi
     fi
     outln

     out "$indent"; pr_bold " OCSP must staple extension   ";
     must_staple "$json_postfix" "$provides_stapling" "$cert_txt"

     out "$indent"; pr_bold " DNS CAA RR"; out " (experimental)    "
     jsonID="DNS_CAArecord"
     caa_node="$NODE"
     caa=""
     while ( [[ -z "$caa" ]] &&  [[ ! -z "$caa_node" ]] ); do
          caa="$(get_caa_rr_record $caa_node)"
          [[ $caa_node =~ '.'$ ]] || caa_node+="."
          caa_node=${caa_node#*.}
     done
     if [[ -n "$caa" ]]; then
          pr_svrty_good "available"; out " - please check for match with \"Issuer\" above"
          if [[ $(count_lines "$caa") -eq 1 ]]; then
               out ": "
          else
               outln; out "$spaces"
          fi
          while read caa; do
               if [[ -n "$caa" ]]; then
                    all_caa+="$caa, "
               fi
          done <<< "$caa"
          all_caa=${all_caa%, }                 # strip trailing comma
          pr_italic "$(out_row_aligned_max_width "$all_caa" "$indent                              " $TERM_WIDTH)"
          fileout "${jsonID}${json_postfix}" "OK" "$all_caa"
     elif [[ -n "$NODNS" ]]; then
          out "(instructed to minimize DNS queries)"
          fileout "${jsonID}${json_postfix}" "INFO" "check skipped as instructed"
     else
          pr_svrty_low "not offered"
          fileout "${jsonID}${json_postfix}" "LOW" "--"
     fi
     outln

     out "$indent"; pr_bold " Certificate Transparency     ";
     jsonID="certificate_transparency"
     if [[ "$ct" =~ extension ]]; then
          pr_svrty_good "yes"; outln " ($ct)"
          fileout "${jsonID}${json_postfix}" "OK" "yes ($ct)"
     else
          outln "$ct"
          fileout "${jsonID}${json_postfix}" "INFO" "$ct"
     fi
     outln
     return $ret
}

run_server_defaults() {
     local ciph newhostcert sni
     local match_found
     local sessticket_lifetime_hint="" sessticket_proto="" lifetime unit
     local -i i n
     local -i certs_found=0
     local -i ret=0
     local -a previous_hostcert previous_hostcert_txt previous_hostcert_type
     local -a previous_hostcert_issuer previous_intermediates previous_ordering_problem keysize cipher
     local -a ocsp_response_binary ocsp_response ocsp_response_status sni_used tls_version ct
     local -a ciphers_to_test certificate_type
     local -a -i success
     local cn_nosni cn_sni sans_nosni sans_sni san tls_extensions
     local using_sockets=true

     "$SSL_NATIVE" && using_sockets=false

     # Try each public key type once:
     # ciphers_to_test[1]: cipher suites using certificates with RSA signature public keys
     # ciphers_to_test[2]: cipher suites using certificates with RSA key encipherment public keys
     # ciphers_to_test[3]: cipher suites using certificates with DSA signature public keys
     # ciphers_to_test[4]: cipher suites using certificates with DH key agreement public keys
     # ciphers_to_test[5]: cipher suites using certificates with ECDH key agreement public keys
     # ciphers_to_test[6]: cipher suites using certificates with ECDSA signature public keys
     # ciphers_to_test[7]: cipher suites using certificates with GOST R 34.10 (either 2001 or 94) public keys
     ciphers_to_test[1]="aRSA:eRSA"
     ciphers_to_test[2]=""
     ciphers_to_test[3]="aDSS:aDH:aECDH:aECDSA:aGOST"
     ciphers_to_test[4]=""
     ciphers_to_test[5]=""
     ciphers_to_test[6]=""
     ciphers_to_test[7]=""
     ciphers_to_test[8]="tls1_3_RSA"
     ciphers_to_test[9]="tls1_3_ECDSA"
     certificate_type[1]="" ; certificate_type[2]=""
     certificate_type[3]=""; certificate_type[4]=""
     certificate_type[5]="" ; certificate_type[6]=""
     certificate_type[7]="" ; certificate_type[8]="RSASig"
     certificate_type[9]="ECDSA"

     for (( n=1; n <= 16 ; n++ )); do
          # Some servers use a different certificate if the ClientHello
          # specifies TLSv1.1 and doesn't include a server name extension.
          # So, for each public key type for which a certificate was found,
          # try again, but only with TLSv1.1 and without SNI.
          if [[ $n -ne 1 ]] && [[ "$OPTIMAL_PROTO" == -ssl2 ]]; then
               ciphers_to_test[n]=""
          elif [[ $n -ge 10 ]]; then
               ciphers_to_test[n]=""
               [[ ${success[n-9]} -eq 0 ]] && [[ $(has_server_protocol "tls1_1") -ne 1 ]] && \
                    ciphers_to_test[n]="${ciphers_to_test[n-9]}" && certificate_type[n]="${certificate_type[n-9]}"
          fi

          if [[ -n "${ciphers_to_test[n]}" ]]; then
               if [[ $n -ge 10 ]]; then
                    sni="$SNI"
                    SNI=""
                    get_server_certificate "${ciphers_to_test[n]}" "tls1_1"
                    success[n]=$?
                    SNI="$sni"
               else
                    get_server_certificate "${ciphers_to_test[n]}"
                    success[n]=$?
               fi
               if [[ ${success[n]} -eq 0 ]] && [[ -s "$HOSTCERT" ]]; then
                    [[ $n -ge 10 ]] && [[ ! -e $HOSTCERT.nosni ]] && cp $HOSTCERT $HOSTCERT.nosni
                    cp "$TEMPDIR/$NODEIP.get_server_certificate.txt" $TMPFILE
                    >$ERRFILE
                    if [[ -z "$sessticket_lifetime_hint" ]]; then
                         sessticket_lifetime_hint=$(awk '/session ticket life/ { if (!found) print; found=1 }' $TMPFILE)
                         sessticket_proto="$(get_protocol "$TMPFILE")"
                    fi

                    if [[ $n -le 7 ]]; then
                         ciph="$(get_cipher $TMPFILE)"
                         if [[ "$ciph" != TLS_* ]] && [[ "$ciph" != SSL_* ]]; then
                              ciph="$(openssl2rfc "$ciph")"
                         fi
                         if [[ "$ciph" == TLS_DHE_RSA_* ]] || [[ "$ciph" == TLS_ECDHE_RSA_* ]] || [[ "$ciph" == TLS_CECPQ1_RSA_* ]]; then
                              certificate_type[n]="RSASig"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aRSA/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aRSA"
                         elif [[ "$ciph" == TLS_RSA_* ]] || [[ "$ciph" == SSL_* ]] || [[ "$ciph" == TLS_GOST*_RSA_* ]]; then
                              certificate_type[n]="RSAKMK"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/eRSA/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="eRSA"
                         elif [[ "$ciph" == TLS_DHE_DSS_* ]]; then
                              certificate_type[n]="DSA"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aDSS/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphe-S 127.0.0.1rs_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aDSS"
                         elif [[ "$ciph" == TLS_DH_* ]]; then
                              certificate_type[n]="DH"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aDH/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aDH"
                         elif [[ "$ciph" == TLS_ECDH_* ]]; then
                              certificate_type[n]="ECDH"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aECDH/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aECDH"
                         elif [[ "$ciph" == TLS_ECDHE_ECDSA_* ]] || [[ "$ciph" == TLS_CECPQ1_ECDSA_* ]]; then
                              certificate_type[n]="ECDSA"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aECDSA/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aECDSA"
                         elif [[ "$ciph" == TLS_GOST* ]]; then
                              certificate_type[n]="GOST"
                              if [[ -z "${ciphers_to_test[n+1]}" ]]; then
                                   ciphers_to_test[n+1]="${ciphers_to_test[n]/aGOST/}"
                                   ciphers_to_test[n+1]="${ciphers_to_test[n+1]/::/:}"
                                   [[ "${ciphers_to_test[n+1]:0:1}" == : ]] && ciphers_to_test[n+1]="${ciphers_to_test[n+1]:1}"
                              fi
                              ciphers_to_test[n]="aGOST"
                         fi
                    fi
                    # check whether the host's certificate has been seen before
                    match_found=false
                    i=1
                    newhostcert=$(cat $HOSTCERT)
                    while [[ $i -le $certs_found ]]; do
                         if [[ "$newhostcert" == "${previous_hostcert[i]}" ]]; then
                              match_found=true
                              break;
                         fi
                         i=$((i + 1))
                    done
                    if ! "$match_found" && [[ $n -ge 10 ]] && [[ $certs_found -ne 0 ]]; then
                         # A new certificate was found using TLSv1.1 without SNI.
                         # Check to see if the new certificate should be displayed.
                         # It should be displayed if it is either a match for the
                         # $NODE being tested or if it has the same subject
                         # (CN and SAN) as other certificates for this host.
                         compare_server_name_to_cert "$HOSTCERT"
                         [[ $? -ne 0 ]] && success[n]=0 || success[n]=1

                         if [[ ${success[n]} -ne 0 ]]; then
                              cn_nosni="$(toupper "$(get_cn_from_cert $HOSTCERT)")"
                              sans_nosni="$(toupper "$(get_san_dns_from_cert "$HOSTCERT")")"

                              echo "${previous_hostcert[1]}" > $HOSTCERT
                              cn_sni="$(toupper "$(get_cn_from_cert $HOSTCERT)")"

                              # FIXME: Not sure what the matching rule should be. At
                              # the moment, the no SNI certificate is considered a
                              # match if the CNs are the same and the SANs (if
                              # present) contain at least one DNS name in common.
                              if [[ "$cn_nosni" == "$cn_sni" ]]; then
                                   sans_sni="$(toupper "$(get_san_dns_from_cert "$HOSTCERT")")"
                                   if [[ "$sans_nosni" == "$sans_sni" ]]; then
                                        success[n]=0
                                   else
                                        while read -r san; do
                                             [[ -n "$san" ]] && [[ " $sans_sni " =~ " $san " ]] && success[n]=0 && break
                                        done <<< "$sans_nosni"
                                   fi
                              fi
                         fi
                         # If the certificate found for TLSv1.1 w/o SNI appears to
                         # be for a different host, then set match_found to true so
                         # that the new certificate will not be included in the output.
                         [[ ${success[n]} -ne 0 ]] && match_found=true
                    fi
                    if ! "$match_found"; then
                         certs_found=$(( certs_found + 1))
                         cipher[certs_found]=${ciphers_to_test[n]}
                         keysize[certs_found]=$(awk '/Server public key/ { print $(NF-1) }' $TMPFILE)
                         # If an OCSP response was sent, then get the full
                         # response so that certificate_info() can determine
                         # whether it includes a certificate transparency extension.
                         ocsp_response_binary[certs_found]="$STAPLED_OCSP_RESPONSE"
                         if grep -a "OCSP response:" $TMPFILE | grep -q "no response sent"; then
                              ocsp_response[certs_found]="$(grep -a "OCSP response" $TMPFILE)"
                         else
                              ocsp_response[certs_found]="$(awk -v n=2 '/OCSP response:/ {start=1; inc=2} /======================================/ { if (start) {inc--} } inc' $TMPFILE)"
                         fi
                         ocsp_response_status[certs_found]=$(grep -a "OCSP Response Status" $TMPFILE)
                         previous_hostcert[certs_found]=$newhostcert
                         previous_hostcert_txt[certs_found]="$($OPENSSL x509 -noout -text 2>>$ERRFILE <<< "$newhostcert")"
                         previous_intermediates[certs_found]=$(cat $TEMPDIR/intermediatecerts.pem)
                         previous_hostcert_issuer[certs_found]=""
                         [[ -n "${previous_intermediates[certs_found]}" ]] && [[ -r $TEMPDIR/hostcert_issuer.pem ]] && \
                              previous_hostcert_issuer[certs_found]=$(cat $TEMPDIR/hostcert_issuer.pem)
                         previous_ordering_problem[certs_found]=$CERTIFICATE_LIST_ORDERING_PROBLEM
                         [[ $n -ge 10 ]] && sni_used[certs_found]="" || sni_used[certs_found]="$SNI"
                         tls_version[certs_found]="$DETECTED_TLS_VERSION"
                         previous_hostcert_type[certs_found]=" ${certificate_type[n]}"
                         if [[ $DEBUG -ge 1 ]]; then
                              echo "${previous_hostcert[certs_found]}" > $TEMPDIR/host_certificate_$certs_found.pem
                              echo "${previous_hostcert_txt[certs_found]}" > $TEMPDIR/host_certificate_$certs_found.txt
                         fi
                    else
                         previous_hostcert_type[i]+=" ${certificate_type[n]}"
                    fi
               fi
          fi
     done

     determine_tls_extensions

     if [[ $? -eq 0 ]] && [[ "$OPTIMAL_PROTO" != -ssl2 ]]; then
          cp "$TEMPDIR/$NODEIP.determine_tls_extensions.txt" $TMPFILE
          >$ERRFILE
          if [[ -z "$sessticket_lifetime_hint" ]]; then
               sessticket_lifetime_hint=$(awk '/session ticket lifetime/ { if (!found) print; found=1 }' $TMPFILE)
               sessticket_proto="$(get_protocol "$TMPFILE")"
          fi
     fi
     if "$using_sockets" && ! "$TLS13_ONLY" && [[ -z "$sessticket_lifetime_hint" ]] && [[ "$OPTIMAL_PROTO" != -ssl2 ]]; then
          if "$HAS_TLS13" && ( [[ -z "$OPTIMAL_PROTO" ]] || [[ "$OPTIMAL_PROTO" == -tls1_3 ]] ) ; then
               # If a session ticket were sent in response to a TLSv1.3 ClientHello, then a session ticket
               # would have been found by get_server_certificate(). So, try again with a TLSv1.2 ClientHello.
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -no_tls1_3 -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>$ERRFILE >$TMPFILE
          else
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS "$OPTIMAL_PROTO" -connect $NODEIP:$PORT $PROXY $SNI") </dev/null 2>$ERRFILE >$TMPFILE
          fi
          if sclient_connect_successful $? $TMPFILE; then
               sessticket_lifetime_hint=$(awk '/session ticket lifetime/ { if (!found) print; found=1 }' $TMPFILE)
               sessticket_proto="$(get_protocol "$TMPFILE")"
          fi
     fi
     [[ -z "$sessticket_lifetime_hint" ]] && TLS_TICKETS=false || TLS_TICKETS=true

     debugme echo "# certificates found $certs_found"
     # Now that all of the server's certificates have been found, determine for
     # each certificate whether certificate transparency information is provided.
     for (( i=1; i <= certs_found; i++ )); do
          ct[i]="$(certificate_transparency "${previous_hostcert_txt[i]}" "${ocsp_response[i]}" "$certs_found" "${cipher[i]}" "${sni_used[i]}" "${tls_version[i]}")"
          # If certificate_transparency() called tls_sockets() and found a "signed certificate timestamps" extension,
          # then add it to $TLS_EXTENSIONS, since it may not have been found by determine_tls_extensions().
          [[ $certs_found -gt 1 ]] && [[ "${ct[i]}" == TLS\ extension ]] && extract_new_tls_extensions "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt"
     done

     outln
     pr_headlineln " Testing server defaults (Server Hello) "
     outln

     pr_bold " TLS extensions (standard)    "
     if [[ -z "$TLS_EXTENSIONS" ]]; then
          outln "(none)"
          fileout "TLS_extensions" "INFO" "(none)"
     else
#FIXME: we rather want to have the chance to print each ext in italics or another format.
# Atm is a string of quoted strings -- that needs to be fixed at the root then
          # out_row_aligned_max_width() places line breaks at space characters.
          # So, in order to prevent the text for an extension from being broken
          # across lines, temporarily replace space characters within the text
          # of an extension with "}", and then convert the "}" back to space in
          # the output of out_row_aligned_max_width().
          tls_extensions="${TLS_EXTENSIONS// /{}"
          tls_extensions="${tls_extensions//\"{\"/\" \"}"
          tls_extensions="$(out_row_aligned_max_width "$tls_extensions" "                              " $TERM_WIDTH)"
          tls_extensions="${tls_extensions//{/ }"
          outln "$tls_extensions"
          fileout "TLS_extensions" "INFO" "$TLS_EXTENSIONS"
     fi

     pr_bold " Session Ticket RFC 5077 hint "
     jsonID="TLS_session_ticket"
     if [[ -z "$sessticket_lifetime_hint" ]]; then
          outln "no -- no lifetime advertised"
          fileout "${jsonID}" "INFO" "no -- no lifetime advertised"
          # it MAY be given a hint of the lifetime of the ticket, see https://tools.ietf.org/html/rfc5077#section-5.6 .
          # Sometimes it just does not -- but it then may also support TLS session tickets reuse
     else
          lifetime=$(grep -a lifetime <<< "$sessticket_lifetime_hint" | sed 's/[A-Za-z:() ]//g')
          unit=$(grep -a lifetime <<< "$sessticket_lifetime_hint" | sed -e 's/^.*'"$lifetime"'//' -e 's/[ ()]//g')
          out "$lifetime $unit"
          if [[ $((3600 * 24)) -lt $lifetime ]]; then
               prln_svrty_low " but: PFS requires session ticket keys to be rotated < daily !"
               fileout "$jsonID" "LOW" "valid for $lifetime $unit (>daily)"
          else
               outln ", session tickets keys seems to be rotated < daily"
               fileout "$jsonID" "INFO" "valid for $lifetime $unit only (<daily)"
          fi
     fi

     pr_bold " SSL Session ID support       "
     jsonID="SSL_sessionID_support"
     if "$NO_SSL_SESSIONID"; then
          outln "no"
          fileout "$jsonID" "INFO" "no"
     else
          outln "yes"
          fileout "$jsonID" "INFO" "yes"
     fi

     pr_bold " Session Resumption           "
     jsonID="sessionresumption_ticket"
     sub_session_resumption "$sessticket_proto"
     case $? in
          0) SESS_RESUMPTION[2]="ticket=yes"
             out "Tickets: yes, "
             fileout "$jsonID" "INFO" "supported"
          ;;
          1) SESS_RESUMPTION[2]="ticket=no"
             out "Tickets no, "
             fileout "$jsonID" "INFO" "not supported"
             ;;
          5) SESS_RESUMPTION[2]="ticket=noclue"
             pr_warning "Ticket resumption test failed, pls report / "
             fileout "$jsonID" "WARN" "check failed, pls report"
             ((ret++))
             ;;
          6) SESS_RESUMPTION[2]="ticket=clientauth"
             pr_warning "Client Auth: Ticket resumption test not supported / "
             fileout "$jsonID" "WARN" "check couldn't be performed because of client authentication"
             ;;
          7) SESS_RESUMPTION[2]="ticket=unsuccessful"
             pr_warning "Connect problem: Ticket resumption test not possible / "
             fileout "$jsonID" "WARN" "check failed because of connect problem"
             ((ret++))
             ;;
     esac

     jsonID="sessionresumption_ID"
     if "$NO_SSL_SESSIONID"; then
          SESS_RESUMPTION[1]="ID=no"
          outln "ID: no"
          fileout "$jsonID" "INFO" "No Session ID, no resumption"
     else
          sub_session_resumption "$sessticket_proto" ID
          case $? in
               0) SESS_RESUMPTION[1]="ID=yes"
                  outln "ID: yes"
                  fileout "$jsonID" "INFO" "supported"
                  ;;
               1|2) SESS_RESUMPTION[1]="ID=no"
                  outln "ID: no"
                  fileout "$jsonID" "INFO" "not supported"
                  ;;
               5) SESS_RESUMPTION[1]="ID=noclue"
                  prln_warning "ID resumption test failed, pls report"
                  fileout "$jsonID" "WARN" "check failed, pls report"
                  ((ret++))
                  ;;
               6) SESS_RESUMPTION[1]="ID=clientauth"
                  [[ ${SESS_RESUMPTION[2]} =~ clientauth ]] || pr_warning "Client Auth: "
                  prln_warning "ID resumption resumption test not supported"
                  fileout "$jsonID" "WARN" "check couldn't be performed because of client authentication"
                  ;;
               7) SESS_RESUMPTION[1]="ID=unsuccessful"
                  prln_warning "ID resumption test failed"
                  fileout "$jsonID" "WARN" "check failed because of connect problem"
                  ((ret++))
                  ;;
          esac
     fi

     tls_time

     if [[ -n "$SNI" ]] && [[ $certs_found -ne 0 ]] && [[ ! -e $HOSTCERT.nosni ]]; then
          # no cipher suites specified here. We just want the default vhost subject
          if ! "$HAS_TLS13" && [[ $(has_server_protocol "tls1_3") -eq 0 ]]; then
               sni="$SNI" ; SNI=""
               mv $HOSTCERT $HOSTCERT.save
               # Send same list of cipher suites as OpenSSL 1.1.1 sends (but with
               # all 5 TLSv1.3 ciphers offered.
               tls_sockets "04" \
                           "c0,2c, c0,30, 00,9f, cc,a9, cc,a8, cc,aa, c0,2b, c0,2f,
                            00,9e, c0,24, c0,28, 00,6b, c0,23, c0,27, 00,67, c0,0a,
                            c0,14, 00,39, c0,09, c0,13, 00,33, 00,9d, 00,9c, 13,02,
                            13,03, 13,01, 13,04, 13,05, 00,3d, 00,3c, 00,35, 00,2f,
                            00,ff" \
                            "all+"
               success[0]=$?
               if [[ ${success[0]} -eq 0 ]] || [[ ${success[0]} -eq 2 ]]; then
                    if [[ -s $HOSTCERT ]]; then
                         mv $HOSTCERT $HOSTCERT.nosni
                    else
                         # The connection was successful, but the certificate could
                         # not be obtained (probably because the connection was TLS 1.3
                         # and $OPENSSL does not support the key exchange group that was
                         # selected). So, try again using OpenSSL (which will not use a TLS 1.3
                         # ClientHello).
                         $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $OPTIMAL_PROTO") 2>>$ERRFILE </dev/null | \
                              awk '/-----BEGIN/,/-----END/ { print $0 }'  >$HOSTCERT.nosni
                    fi
               else
                    >$HOSTCERT.nosni
               fi
               mv $HOSTCERT.save $HOSTCERT
               SNI="$sni"
          else
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $OPTIMAL_PROTO") 2>>$ERRFILE </dev/null | \
                    awk '/-----BEGIN/,/-----END/ { print $0 }'  >$HOSTCERT.nosni
          fi
     elif [[ $certs_found -eq 0 ]] && [[ -s "$HOSTCERT" ]]; then
          outln
          generic_nonfatal "Client problem, shouldn't happen: Host certificate found but we can't continue with \"server defaults\"."
     elif [[ $certs_found -eq 0 ]]; then
          outln
          if $TLS13_ONLY; then
               generic_nonfatal "Client problem: We need openssl supporting TLS 1.3. We can't continue with \"server defaults\" as we cannot retrieve the certificate. "
          else
               generic_nonfatal "Client problem, No server cerificate could be retrieved. Thus we can't continue with \"server defaults\"."
          fi
     fi
     [[ $DEBUG -ge 1 ]] && [[ -e $HOSTCERT.nosni ]] && $OPENSSL x509 -in $HOSTCERT.nosni -text -noout 2>>$ERRFILE > $HOSTCERT.nosni.txt

     fileout "cert_numbers" "INFO" "$certs_found"
     for (( i=1; i <= certs_found; i++ )); do
          echo "${previous_hostcert[i]}" > $HOSTCERT
          echo "${previous_intermediates[i]}" > $TEMPDIR/intermediatecerts.pem
          echo "${previous_hostcert_issuer[i]}" > $TEMPDIR/hostcert_issuer.pem
          certificate_info "$i" "$certs_found" "${previous_hostcert_txt[i]}" \
               "${cipher[i]}" "${keysize[i]}" "${previous_hostcert_type[i]}" \
               "${ocsp_response_binary[i]}" "${ocsp_response[i]}" \
               "${ocsp_response_status[i]}" "${sni_used[i]}" "${ct[i]}" \
               "${previous_ordering_problem[i]}"
               [[ $? -ne 0 ]] && ((ret++))
     done
     return $ret
}

get_session_ticket_lifetime_from_serverhello() {
     awk '/session ticket.*lifetime/ { print $(NF-1) "$1" }'
}

get_san_dns_from_cert() {
     echo "$($OPENSSL x509 -in "$1" -noout -text 2>>$ERRFILE | \
          grep -A2 "Subject Alternative Name" | tr ',' '\n' | grep "DNS:" | \
          sed -e 's/DNS://g' -e 's/ //g')"
}


run_pfs() {
     local -i sclient_success
     local pfs_offered=false ecdhe_offered=false ffdhe_offered=false
     local pfs_tls13_offered=false
     local protos_to_try proto hexc dash pfs_cipher sslvers auth mac export curve dhlen
     local -a hexcode normalized_hexcode ciph rfc_ciph kx enc ciphers_found sigalg ossl_supported
     # generated from 'kEECDH:kEDH:!aNULL:!eNULL:!DES:!3DES:!RC4' with openssl 1.0.2i and openssl 1.1.0
     local pfs_cipher_list="DHE-DSS-AES128-GCM-SHA256:DHE-DSS-AES128-SHA256:DHE-DSS-AES128-SHA:DHE-DSS-AES256-GCM-SHA384:DHE-DSS-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-DSS-CAMELLIA128-SHA256:DHE-DSS-CAMELLIA128-SHA:DHE-DSS-CAMELLIA256-SHA256:DHE-DSS-CAMELLIA256-SHA:DHE-DSS-SEED-SHA:DHE-RSA-AES128-CCM8:DHE-RSA-AES128-CCM:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-CCM8:DHE-RSA-AES256-CCM:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-CAMELLIA128-SHA256:DHE-RSA-CAMELLIA128-SHA:DHE-RSA-CAMELLIA256-SHA256:DHE-RSA-CAMELLIA256-SHA:DHE-RSA-CHACHA20-POLY1305-OLD:DHE-RSA-CHACHA20-POLY1305:DHE-RSA-SEED-SHA:ECDHE-ECDSA-AES128-CCM8:ECDHE-ECDSA-AES128-CCM:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-ECDSA-AES256-CCM8:ECDHE-ECDSA-AES256-CCM:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-CAMELLIA128-SHA256:ECDHE-ECDSA-CAMELLIA256-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305-OLD:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-RSA-CAMELLIA128-SHA256:ECDHE-RSA-CAMELLIA256-SHA384:ECDHE-RSA-CHACHA20-POLY1305-OLD:ECDHE-RSA-CHACHA20-POLY1305"
     local pfs_hex_cipher_list="" ciphers_to_test tls13_ciphers_to_test
     local ecdhe_cipher_list="" tls13_cipher_list="" ecdhe_cipher_list_hex="" ffdhe_cipher_list_hex=""
     local curves_hex=("00,01" "00,02" "00,03" "00,04" "00,05" "00,06" "00,07" "00,08" "00,09" "00,0a" "00,0b" "00,0c" "00,0d" "00,0e" "00,0f" "00,10" "00,11" "00,12" "00,13" "00,14" "00,15" "00,16" "00,17" "00,18" "00,19" "00,1a" "00,1b" "00,1c" "00,1d" "00,1e")
     local -a curves_ossl=("sect163k1" "sect163r1" "sect163r2" "sect193r1" "sect193r2" "sect233k1" "sect233r1" "sect239k1" "sect283k1" "sect283r1" "sect409k1" "sect409r1" "sect571k1" "sect571r1" "secp160k1" "secp160r1" "secp160r2" "secp192k1" "prime192v1" "secp224k1" "secp224r1" "secp256k1" "prime256v1" "secp384r1" "secp521r1" "brainpoolP256r1" "brainpoolP384r1" "brainpoolP512r1" "X25519" "X448")
     local -a curves_ossl_output=("K-163" "sect163r1" "B-163" "sect193r1" "sect193r2" "K-233" "B-233" "sect239k1" "K-283" "B-283" "K-409" "B-409" "K-571" "B-571" "secp160k1" "secp160r1" "secp160r2" "secp192k1" "P-192" "secp224k1" "P-224" "secp256k1" "P-256" "P-384" "P-521" "brainpoolP256r1" "brainpoolP384r1" "brainpoolP512r1" "X25519" "X448")
     local -ai curves_bits=(163 162 163 193 193 232 233 238 281 282 407 409 570 570 161 161 161 192 192 225 224 256 256 384 521 256 384 512 253 448)
     # Many curves have been deprecated, and RFC 8446, Appendix B.3.1.4, states
     # that these curves MUST NOT be offered in a TLS 1.3 ClientHello.
     local -a curves_deprecated=("true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "true" "false" "false" "false" "true" "true" "true" "false" "false")
     local -a ffdhe_groups_hex=("01,00" "01,01" "01,02" "01,03" "01,04")
     local -a ffdhe_groups_output=("ffdhe2048" "ffdhe3072" "ffdhe4096" "ffdhe6144" "ffdhe8192")
     local -a supported_curve
     local -i nr_supported_ciphers=0 nr_curves=0 nr_ossl_curves=0 i j low high
     local pfs_ciphers curves_offered="" curves_to_test temp
     local len1 len2 curve_found
     local key_bitstring quality_str
     local -i len_dh_p quality
     local has_dh_bits="$HAS_DH_BITS"
     local using_sockets=true
     local jsonID="PFS"

     "$SSL_NATIVE" && using_sockets=false
     "$FAST" && using_sockets=false
     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

     outln
     pr_headline " Testing robust (perfect) forward secrecy"; prln_underline ", (P)FS -- omitting Null Authentication/Encryption, 3DES, RC4 "
     if ! "$using_sockets"; then
          [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && pr_warning " Cipher mapping not available, doing a fallback to openssl"
          if ! "$HAS_DH_BITS" && "$WIDE"; then
               [[ $TLS_NR_CIPHERS == 0 ]] && ! "$SSL_NATIVE" && ! "$FAST" && out "."
               pr_warning "    (Your $OPENSSL cannot show DH/ECDH bits)"
          fi
          outln
     fi

     if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               pfs_cipher="${TLS_CIPHER_RFC_NAME[i]}"
               hexc="${TLS_CIPHER_HEXCODE[i]}"
               if ( [[ "$pfs_cipher" == "TLS_DHE_"* ]] || [[ "$pfs_cipher" == "TLS_ECDHE_"* ]] || [[ "${hexc:2:2}" == "13" ]] ) && \
                  [[ ! "$pfs_cipher" =~ NULL ]] && [[ ! "$pfs_cipher" =~ DES ]] && [[ ! "$pfs_cipher" =~ RC4 ]] && \
                  [[ ! "$pfs_cipher" =~ PSK ]] && ( "$using_sockets" || "${TLS_CIPHER_OSSL_SUPPORTED[i]}" ); then
                    pfs_hex_cipher_list+=", ${hexc:2:2},${hexc:7:2}"
                    ciph[nr_supported_ciphers]="${TLS_CIPHER_OSSL_NAME[i]}"
                    rfc_ciph[nr_supported_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                    kx[nr_supported_ciphers]="${TLS_CIPHER_KX[i]}"
                    enc[nr_supported_ciphers]="${TLS_CIPHER_ENC[i]}"
                    ciphers_found[nr_supported_ciphers]=false
                    sigalg[nr_supported_ciphers]=""
                    ossl_supported[nr_supported_ciphers]="${TLS_CIPHER_OSSL_SUPPORTED[i]}"
                    hexcode[nr_supported_ciphers]="${hexc:2:2},${hexc:7:2}"
                    if [[ "${hexc:2:2}" == 00 ]]; then
                         normalized_hexcode[nr_supported_ciphers]="x${hexc:7:2}"
                    else
                         normalized_hexcode[nr_supported_ciphers]="x${hexc:2:2}${hexc:7:2}"
                    fi
                    "$using_sockets" && ! "$has_dh_bits" && "$WIDE" && ossl_supported[nr_supported_ciphers]=false
                    nr_supported_ciphers+=1
               fi
          done
     else
          while read -r hexc dash ciph[nr_supported_ciphers] sslvers kx[nr_supported_ciphers] auth enc[nr_supported_ciphers] mac export; do
               ciphers_found[nr_supported_ciphers]=false
               if [[ "${hexc:2:2}" == 00 ]]; then
                    normalized_hexcode[nr_supported_ciphers]="x${hexc:7:2}"
               else
                    normalized_hexcode[nr_supported_ciphers]="x${hexc:2:2}${hexc:7:2}"
               fi
               sigalg[nr_supported_ciphers]=""
               ossl_supported[nr_supported_ciphers]=true
               nr_supported_ciphers+=1
          done < <(actually_supported_ciphers "$pfs_cipher_list" "ALL" "-V")
     fi
     export=""

     if [[ $(has_server_protocol "tls1_3") -eq 0 ]]; then
          # All TLSv1.3 cipher suites offer robust PFS.
          sclient_success=0
     elif "$using_sockets"; then
          tls_sockets "04" "${pfs_hex_cipher_list:2}, 00,ff"
          sclient_success=$?
          [[ $sclient_success -eq 2 ]] && sclient_success=0
     else
          debugme echo $nr_supported_ciphers
          debugme echo $(actually_supported_ciphers $pfs_cipher_list "ALL")
          if [[ "$nr_supported_ciphers" -le "$CLIENT_MIN_PFS" ]]; then
               outln
               prln_local_problem "You only have $nr_supported_ciphers PFS ciphers on the client side "
               fileout "$jsonID" "WARN" "tests skipped as you only have $nr_supported_ciphers PFS ciphers on the client site. ($CLIENT_MIN_PFS are required)"
               return 1
          fi
          $OPENSSL s_client $(s_client_options "-cipher $pfs_cipher_list -ciphersuites "ALL" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
          [[ $sclient_success -eq 0 ]] && [[ $(grep -ac "BEGIN CERTIFICATE" $TMPFILE) -eq 0 ]] && sclient_success=1
     fi

     if [[ $sclient_success -ne 0 ]]; then
          outln
          prln_svrty_medium " No ciphers supporting Forward Secrecy offered"
          fileout "$jsonID" "MEDIUM" "No ciphers supporting (P)FS offered"
     else
          outln
          pfs_offered=true
          pfs_ciphers=""
          pr_svrty_good " PFS is offered (OK)"
          fileout "$jsonID" "OK" "offered"
          if "$WIDE"; then
               outln ", ciphers follow (client/browser support is important here) \n"
               neat_header
          else
               out "          "
          fi
          if "$HAS_TLS13"; then
               protos_to_try="-no_ssl2 -no_tls1_3"
          else
               protos_to_try="-no_ssl2"
          fi

          for proto in $protos_to_try; do
               while true; do
                    ciphers_to_test=""
                    tls13_ciphers_to_test=""
                    for (( i=0; i < nr_supported_ciphers; i++ )); do
                         if ! "${ciphers_found[i]}" && "${ossl_supported[i]}"; then
                              if [[ "${ciph[i]}" == TLS13* ]] || [[ "${ciph[i]}" == TLS_* ]]; then
                                   tls13_ciphers_to_test+=":${ciph[i]}"
                              else
                                   ciphers_to_test+=":${ciph[i]}"
                              fi
                         fi
                    done
                    [[ -z "$ciphers_to_test" ]] && [[ -z "$tls13_ciphers_to_test" ]] && break
                    $OPENSSL s_client $(s_client_options "$proto -cipher "\'${ciphers_to_test:1}\'" -ciphersuites "\'${tls13_ciphers_to_test:1}\'" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") &>$TMPFILE </dev/null
                    sclient_connect_successful $? $TMPFILE || break
                    pfs_cipher=$(get_cipher $TMPFILE)
                    [[ -z "$pfs_cipher" ]] && break
                    for (( i=0; i < nr_supported_ciphers; i++ )); do
                         [[ "$pfs_cipher" == "${ciph[i]}" ]] && break
                    done
                    [[ $i -eq $nr_supported_ciphers ]] && break
                    ciphers_found[i]=true
                    if [[ "$pfs_cipher" == TLS13* ]] || [[ "$pfs_cipher" == TLS_* ]]; then
                         pfs_tls13_offered=true
                         "$WIDE" && kx[i]="$(read_dhtype_from_file $TMPFILE)"
                    fi
                    if "$WIDE"; then
                         dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                         kx[i]="${kx[i]} $dhlen"
                    fi
                    "$WIDE" && "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                         sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
               done
          done
          if "$using_sockets"; then
               for proto in 04 03; do
                    while true; do
                         ciphers_to_test=""
                         for (( i=0; i < nr_supported_ciphers; i++ )); do
                              ! "${ciphers_found[i]}" && ciphers_to_test+=", ${hexcode[i]}"
                         done
                         [[ -z "$ciphers_to_test" ]] && break
                         [[ "$proto" == "04" ]] && [[ ! "$ciphers_to_test" =~ ,\ 13,[0-9a-f][0-9a-f] ]] && break
                         ciphers_to_test="$(strip_inconsistent_ciphers "$proto" "$ciphers_to_test")"
                         [[ -z "$ciphers_to_test" ]] && break
                         if "$WIDE" && "$SHOW_SIGALGO"; then
                              tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "all"
                         else
                              tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
                         fi
                         sclient_success=$?
                         [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
                         pfs_cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                         for (( i=0; i < nr_supported_ciphers; i++ )); do
                              [[ "$pfs_cipher" == "${rfc_ciph[i]}" ]] && break
                         done
                         [[ $i -eq $nr_supported_ciphers ]] && break
                         ciphers_found[i]=true
                         if [[ "${kx[i]}" == Kx=any ]]; then
                              pfs_tls13_offered=true
                              "$WIDE" && kx[i]="$(read_dhtype_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")"
                         fi
                         if "$WIDE"; then
                              dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                              kx[i]="${kx[i]} $dhlen"
                         fi
                         "$WIDE" && "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && \
                              sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
                    done
               done
          fi
          for (( i=0; i < nr_supported_ciphers; i++ )); do
               ! "${ciphers_found[i]}" && ! "$SHOW_EACH_C" && continue
               if "${ciphers_found[i]}"; then
                    if ( [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ "${ciph[i]}" != "-" ]] ) || [[ "${rfc_ciph[i]}" == "-" ]]; then
                         pfs_cipher="${ciph[i]}"
                    else
                         pfs_cipher="${rfc_ciph[i]}"
                    fi
                    pfs_ciphers+="$pfs_cipher "

                    if [[ "${ciph[i]}" == ECDHE-* ]] || [[ "${ciph[i]}" == TLS13* ]] || [[ "${ciph[i]}" == TLS_* ]] || ( "$using_sockets" && [[ "${rfc_ciph[i]}" == TLS_ECDHE_* ]] ); then
                         ecdhe_offered=true
                         ecdhe_cipher_list_hex+=", ${hexcode[i]}"
                         if [[ "${ciph[i]}" != "-" ]]; then
                              if  [[ "${ciph[i]}" == TLS13* ]] || [[ "${ciph[i]}" == TLS_* ]]; then
                                   tls13_cipher_list+=":$pfs_cipher"
                              else
                                   ecdhe_cipher_list+=":$pfs_cipher"
                              fi
                         fi
                    fi
                    if [[ "${ciph[i]}" == "DHE-"* ]] || ( "$using_sockets" && [[ "${rfc_ciph[i]}" == "TLS_DHE_"* ]] ); then
                         ffdhe_offered=true
                         ffdhe_cipher_list_hex+=", ${hexcode[i]}"
                    elif [[ "${ciph[i]}" == TLS13* ]] || [[ "${ciph[i]}" == TLS_* ]]; then
                         ffdhe_cipher_list_hex+=", ${hexcode[i]}"
                    fi
               fi
               if "$WIDE"; then
                    neat_list "$(tolower "${normalized_hexcode[i]}")" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
                    if "$SHOW_EACH_C"; then
                         if "${ciphers_found[i]}"; then
                              pr_cipher_quality "${rfc_ciph[i]}" "available"
                         else
                              pr_deemphasize "not a/v"
                         fi
                    fi
                    outln "${sigalg[i]}"
               fi
          done
          if ! "$WIDE"; then
               if [[ "$COLOR" -le 2 ]]; then
                    out "$(out_row_aligned_max_width "$pfs_ciphers" "                              " $TERM_WIDTH)"
               else
                    out_row_aligned_max_width_by_entry "$pfs_ciphers" "                              " $TERM_WIDTH pr_cipher_quality
               fi
          fi
          debugme echo $pfs_offered
          "$WIDE" || outln
          fileout "${jsonID}_ciphers" "INFO" "$pfs_ciphers"
     fi

     # find out what elliptic curves are supported.
     if "$ecdhe_offered"; then
          for curve in "${curves_ossl[@]}"; do
               ossl_supported[nr_curves]=false
               supported_curve[nr_curves]=false
               [[ "$OSSL_SUPPORTED_CURVES" =~ " $curve " ]] && ossl_supported[nr_curves]=true && nr_ossl_curves+=1
               nr_curves+=1
          done

          # OpenSSL limits the number of curves that can be specified in the
          # "-curves" option to 28. So, break the list in two if there are more
          # than 28 curves supported by OpenSSL.
          for j in 1 2; do
               if [[ $j -eq 1 ]]; then
                    if [[ $nr_ossl_curves -le 28 ]]; then
                         low=0; high=$nr_curves
                    else
                         low=0; high=$nr_curves/2
                    fi
               else
                    if [[ $nr_ossl_curves -le 28 ]]; then
                         continue # all curves tested in first round
                    else
                         low=$nr_curves/2; high=$nr_curves
                    fi
               fi
               if "$HAS_TLS13"; then
                    if "$pfs_tls13_offered"; then
                         protos_to_try="-no_ssl2 -no_tls1_3"
                    else
                         protos_to_try="-no_tls1_3"
                    fi
               else
                    protos_to_try="-no_ssl2"
               fi

               for proto in $protos_to_try; do
                    while true; do
                         curves_to_test=""
                         for (( i=low; i < high; i++ )); do
                              if ! "$HAS_TLS13" || ! "${curves_deprecated[i]}" || [[ "$proto" == "-no_tls1_3" ]]; then
                                   "${ossl_supported[i]}" && ! "${supported_curve[i]}" && curves_to_test+=":${curves_ossl[i]}"
                              fi
                         done
                         [[ -z "$curves_to_test" ]] && break
                         $OPENSSL s_client $(s_client_options "$proto -cipher "\'${ecdhe_cipher_list:1}\'" -ciphersuites "\'${tls13_cipher_list:1}\'" -curves "${curves_to_test:1}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") &>$TMPFILE </dev/null
                         sclient_connect_successful $? $TMPFILE || break
                         temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TMPFILE")
                         curve_found="${temp%%,*}"
                         if [[ "$curve_found" == ECDH ]]; then
                              curve_found="${temp#*, }"
                              curve_found="${curve_found%%,*}"
                         fi
                         for (( i=low; i < high; i++ )); do
                              ! "${supported_curve[i]}" && [[ "${curves_ossl_output[i]}" == "$curve_found" ]] && break
                         done
                         [[ $i -eq $high ]] && break
                         supported_curve[i]=true
                    done
               done
          done
     fi
     if "$ecdhe_offered" && "$using_sockets"; then
          protos_to_try="03"
          "$pfs_tls13_offered" && protos_to_try="04 03"
          for proto in $protos_to_try; do
               if [[ "$proto" == 03 ]]; then
                    ecdhe_cipher_list_hex="$(strip_inconsistent_ciphers "03" "$ecdhe_cipher_list_hex")"
                    [[ -z "$ecdhe_cipher_list_hex" ]] && continue
               fi
               while true; do
                    curves_to_test=""
                    for (( i=0; i < nr_curves; i++ )); do
                         if ! "${curves_deprecated[i]}" || [[ "$proto" == 03 ]]; then
                              ! "${supported_curve[i]}" && curves_to_test+=", ${curves_hex[i]}"
                         fi
                    done
                    [[ -z "$curves_to_test" ]] && break
                    len1=$(printf "%02x" "$((2*${#curves_to_test}/7))")
                    len2=$(printf "%02x" "$((2*${#curves_to_test}/7+2))")
                    tls_sockets "$proto" "${ecdhe_cipher_list_hex:2}, 00,ff" "ephemeralkey" "00, 0a, 00, $len2, 00, $len1, ${curves_to_test:2}"
                    sclient_success=$?
                    [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
                    temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                    curve_found="${temp%%,*}"
                    if [[ "$curve_found" == "ECDH" ]]; then
                         curve_found="${temp#*, }"
                         curve_found="${curve_found%%,*}"
                    fi
                    for (( i=0; i < nr_curves; i++ )); do
                         ! "${supported_curve[i]}" && [[ "${curves_ossl_output[i]}" == "$curve_found" ]] && break
                    done
                    [[ $i -eq $nr_curves ]] && break
                    supported_curve[i]=true
               done
          done
     fi
     if "$ecdhe_offered"; then
          low=1000
          for (( i=0; i < nr_curves; i++ )); do
               if "${supported_curve[i]}"; then
                    curves_offered+="${curves_ossl[i]} "
                    [[ ${curves_bits[i]} -lt $low ]] && low=${curves_bits[i]}
               fi
          done
          if [[ -n "$curves_offered" ]]; then
               "$WIDE" && outln
               pr_bold " Elliptic curves offered:     "
               out_row_aligned_max_width_by_entry "$curves_offered" "                              " $TERM_WIDTH pr_ecdh_curve_quality
               outln
               # severity ratings based on quality specified by
               # pr_ecdh_quality() for shortest curve offered.
               if [[ "$low" -le 163 ]]; then
                    fileout "${jsonID}_ECDHE_curves" "MEDIUM" "$curves_offered"
               elif [[ "$low" -le 193 ]]; then
                    fileout "${jsonID}_ECDHE_curves" "LOW" "$curves_offered"
               elif [[ "$low" -le 224 ]]; then
                    fileout "${jsonID}_ECDHE_curves" "INFO" "$curves_offered"
               else
                    fileout "${jsonID}_ECDHE_curves" "OK" "$curves_offered"
               fi
          fi
     fi
     CURVES_OFFERED="$curves_offered"
     CURVES_OFFERED=$(strip_trailing_space "$CURVES_OFFERED")

     # find out what groups are supported.
     if "$using_sockets" && ( "$pfs_tls13_offered" || "$ffdhe_offered" ); then
          nr_curves=0
          for curve in "${ffdhe_groups_output[@]}"; do
               supported_curve[nr_curves]=false
               [[ "$DH_GROUP_OFFERED" =~ $curve ]] && supported_curve[nr_curves]=true
               nr_curves+=1
          done
          protos_to_try=""
          "$pfs_tls13_offered" && protos_to_try="04"
          if "$ffdhe_offered"; then
               if "$pfs_tls13_offered"; then
                    protos_to_try="04 03"
               else
                    protos_to_try="03"
               fi
          fi
          curve_found=""
          for proto in $protos_to_try; do
               while true; do
                    curves_to_test=""
                    for (( i=0; i < nr_curves; i++ )); do
                         ! "${supported_curve[i]}" && curves_to_test+=", ${ffdhe_groups_hex[i]}"
                    done
                    [[ -z "$curves_to_test" ]] && break
                    len1=$(printf "%02x" "$((2*${#curves_to_test}/7))")
                    len2=$(printf "%02x" "$((2*${#curves_to_test}/7+2))")
                    tls_sockets "$proto" "${ffdhe_cipher_list_hex:2}, 00,ff" "ephemeralkey" "00, 0a, 00, $len2, 00, $len1, ${curves_to_test:2}"
                    sclient_success=$?
                    [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
                    temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                    curve_found="${temp#*, }"
                    curve_found="${curve_found%%,*}"
                    if [[ "$proto" == "03" ]] && [[ -z "$DH_GROUP_OFFERED" ]] && [[ "$curve_found" =~ ffdhe ]]; then
                         DH_GROUP_OFFERED="RFC7919/$curve_found"
                         DH_GROUP_LEN_P="${curve_found#ffdhe}"
                    fi
                    [[ ! "$curve_found" =~ ffdhe ]] && break
                    for (( i=0; i < nr_curves; i++ )); do
                         ! "${supported_curve[i]}" && [[ "${ffdhe_groups_output[i]}" == "$curve_found" ]] && break
                    done
                    [[ $i -eq $nr_curves ]] && break
                    supported_curve[i]=true
               done
          done
          curves_offered=""
          for (( i=0; i < nr_curves; i++ )); do
               "${supported_curve[i]}" && curves_offered+="${ffdhe_groups_output[i]} "
          done
          curves_offered="$(strip_trailing_space "$curves_offered")"
          if "$ffdhe_offered" && [[ -z "$curves_offered" ]] && [[ -z "$curve_found" ]]; then
               # Some servers will fail if the supported_groups extension is present.
               tls_sockets "03" "${ffdhe_cipher_list_hex:2}, 00,ff" "ephemeralkey"
               sclient_success=$?
               if [[ $sclient_success -eq 0 ]] || [[ $sclient_success -eq 2 ]]; then
                    temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                    curve_found="${temp#*, }"
                    curve_found="${curve_found%%,*}"
               fi
          fi
          if [[ -z "$curves_offered" ]] && [[ -n "$curve_found" ]]; then
               # The server is not using one of the groups from RFC 7919.
               if [[ -z "$DH_GROUP_OFFERED" ]]; then
                    # this global will get the name of the group either here or in run_logjam()
                    key_bitstring="$(awk '/-----BEGIN PUBLIC KEY/,/-----END PUBLIC KEY/ { print $0 }' $TEMPDIR/$NODEIP.parse_tls_serverhello.txt)"
                    get_common_prime "$jsonID" "$key_bitstring" ""
                    [[ $? -eq 0 ]] && curves_offered="$DH_GROUP_OFFERED" && len_dh_p=$DH_GROUP_LEN_P
               else
                    curves_offered="$DH_GROUP_OFFERED"
                    len_dh_p=$DH_GROUP_LEN_P
               fi
          fi
          if [[ -n "$curves_offered" ]]; then
               if [[ ! "$curves_offered" =~ ffdhe ]] || [[ ! "$curves_offered" =~ \  ]]; then
                    pr_bold " DH group offered:            "
               else
                    pr_bold " Finite field group:          "
               fi
               if [[ "$curves_offered" =~ ffdhe ]]; then
                    # ok not to display them in italics:
                    pr_svrty_good "$curves_offered"
                    quality=6
               else
                    pr_dh "$curves_offered" "$len_dh_p"
                    quality=$?
               fi
               case "$quality" in
                    1) quality_str="CRITICAL" ;;
                    2) quality_str="HIGH" ;;
                    3) quality_str="MEDIUM" ;;
                    4) quality_str="LOW" ;;
                    5) quality_str="INFO" ;;
                    6|7) quality_str="OK" ;;
               esac
               if [[ "$curves_offered" =~ Unknown ]]; then
                    fileout "DH_groups" "$quality_str" "$curves_offered ($len_dh_p bits)"
               else
                    fileout "DH_groups" "$quality_str" "$curves_offered"
               fi
          fi
     fi
     outln

     tmpfile_handle ${FUNCNAME[0]}.txt
     "$using_sockets" && HAS_DH_BITS="$has_dh_bits"
     return 0
}


# good source for configuration and bugs: https://wiki.mozilla.org/Security/Server_Side_TLS
# good start to read: http://en.wikipedia.org/wiki/Transport_Layer_Security#Attacks_against_TLS.2FSSL


npn_pre(){
     if [[ -n "$PROXY" ]]; then
          pr_warning "not tested as proxies do not support proxying it"
          fileout "NPN" "WARN" "not tested as proxies do not support proxying it"
          return 1
     fi
     if ! "$HAS_NPN"; then
          pr_local_problem "$OPENSSL doesn't support NPN/SPDY";
          fileout "NPN" "WARN" "not tested $OPENSSL doesn't support NPN/SPDY"
          return 7
     fi
     return 0
}

alpn_pre(){
     if [[ -n "$PROXY" ]]; then
          pr_warning "not tested as proxies do not support proxying it"
          fileout "ALPN" "WARN" "not tested as proxies do not support proxying it"
          return 1
     fi
     if ! "$HAS_ALPN" && "$SSL_NATIVE"; then
          prln_local_problem "$OPENSSL doesn't support ALPN/HTTP2";
          fileout "ALPN" "WARN" "not tested as $OPENSSL does not support it"
          return 7
     fi
     return 0
}

# modern browsers do not support it anymore but we should still test it at least for fingerprinting the server side
# Thus we don't label any support for NPN as good.
# FAST mode skips this test
run_npn() {
     local tmpstr
     local -i ret=0
     local jsonID="NPN"

     [[ -n "$STARTTLS" ]] && return 0
     "$FAST" && return 0
     pr_bold " NPN/SPDY   "
     if ! npn_pre; then
          outln
          return 0
     fi
     $OPENSSL s_client $(s_client_options "-connect $NODEIP:$PORT $BUGS $SNI -nextprotoneg "$NPN_PROTOs"") </dev/null 2>$ERRFILE >$TMPFILE
     [[ $? -ne 0 ]] && ret=1
     tmpstr="$(grep -a '^Protocols' $TMPFILE | sed 's/Protocols.*: //')"
     if [[ -z "$tmpstr" ]] || [[ "$tmpstr" == " " ]]; then
          outln "not offered"
          fileout "$jsonID" "INFO" "not offered"
     else
          # now comes a strange thing: "Protocols advertised by server:" is empty but connection succeeded
          if [[ "$tmpstr" =~ [h2|spdy|http] ]]; then
               out "$tmpstr"
               outln " (advertised)"
               fileout "$jsonID" "INFO" "offered with $tmpstr (advertised)"
          else
               prln_cyan "please check manually, server response was ambiguous ..."
               fileout "$jsonID" "INFO" "please check manually, server response was ambiguous ..."
               ((ret++))
          fi
     fi
     # btw: nmap can do that too http://nmap.org/nsedoc/scripts/tls-nextprotoneg.html
     # nmap --script=tls-nextprotoneg #NODE -p $PORT is your friend if your openssl doesn't want to test this
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}


run_alpn() {
     local tmpstr alpn_extn len
     local -i ret=0
     local has_alpn_proto=false
     local alpn_finding=""
     local jsonID="ALPN"

     [[ -n "$STARTTLS" ]] && return 0
     pr_bold " ALPN/HTTP2 "
     if ! alpn_pre; then
          outln
          return 0
     fi
     for proto in $ALPN_PROTOs; do
          # for some reason OpenSSL doesn't list the advertised protocols, so instead try common protocols
          if "$HAS_ALPN"; then
               $OPENSSL s_client $(s_client_options "-connect $NODEIP:$PORT $BUGS $SNI -alpn $proto") </dev/null 2>$ERRFILE >$TMPFILE
          else
               alpn_extn="$(printf "%02x" ${#proto}),$(string_to_asciihex "$proto")"
               len="$(printf "%04x" $((${#proto}+1)))"
               alpn_extn="${len:0:2},${len:2:2},$alpn_extn"
               len="$(printf "%04x" $((${#proto}+3)))"
               alpn_extn="00,10,${len:0:2},${len:2:2},$alpn_extn"
               tls_sockets "03" "$TLS12_CIPHER" "all+" "$alpn_extn"
               if [[ -r "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" ]]; then
                    cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
               else
                    echo "" > $TMPFILE
               fi
          fi
          tmpstr="$(awk -F':' '/^ALPN protocol*:/ { print $2 }' $TMPFILE)"
          if [[ "$tmpstr" == *"$proto" ]]; then
               if ! $has_alpn_proto; then
                    has_alpn_proto=true
               else
                    out ", "
               fi
               # only h2 is what browser need to use HTTP/2.0 and brings a security,privacy and performance benefit
               if [[ "$proto" == "h2" ]]; then
                    pr_svrty_good "$proto"
                    fileout "${jsonID}_HTTP2" "OK" "$proto"
               else
                    out "$proto"
                    alpn_finding+="$proto"
               fi
          fi
     done
     if $has_alpn_proto; then
          outln " (offered)"
          # if h2 is not the only protocol:
          [[ -n "$alpn_finding" ]] && fileout "$jsonID" "INFO" "$alpn_finding"
     else
          outln "not offered"
          fileout "$jsonID" "INFO" "not offered"
     fi
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}

# arg1: string to send
# arg2: possible success strings a egrep pattern, needed!
# arg3: wait in seconds
starttls_io() {
     local waitsleep=$STARTTLS_SLEEP
     local buffer=""

     [[ -n "$3" ]] && waitsleep=$3
     [[ -z "$2" ]] && echo "FIXME $((LINENO))"

     # If there's a sending part it's IO. Postgres sends via socket and replies via
     # strings "S". So there's no I part of IO ;-)
     if [[ -n "$1" ]]; then
          debugme echo -en "C: \"$1\""
          echo -en "$1" >&5
     fi

     # This seems a bit dangerous but works. No blockings yet. "if=nonblock" doesn't work on BSDs
     buffer="$(dd bs=512 count=1 <&5 2>/dev/null)"
     [[ "$DEBUG" -ge 2 ]] && echo -en "\nS: " && echo $buffer

     for ((i=1; i < $waitsleep; i++ )); do
          if [[ "$buffer" =~ $2 ]]; then
               debugme echo "     ---> reply matched \"$2\""
               # the fd sometimes still seem to contain chars which confuses the following TLS handshake, trying to empty:
               dd of=/dev/null bs=512 count=1 <&5 2>/dev/null
               return 0
          else
               # no match yet, more reading from fd helps.
               buffer+=$(dd bs=512 count=1 <&5 2>/dev/null)
          fi
          sleep 0.5
     done
     return 0
}


# Line-based send with newline characters appended (arg2 empty)
# Stream-based send: arg2: <any>
starttls_just_send(){
     if [[ -z "$2" ]] ; then
          debugme echo -e "C: $1 plus lf"
          echo -ne "$1\r\n" >&5
     else
          debugme echo -e "C: $1"
          echo -ne "$1" >&5
     fi
     return $?
}

# arg1: (optional): wait time
starttls_just_read(){
     local waitsleep=$STARTTLS_SLEEP
     [[ -n "$1" ]] && waitsleep=$1
     if [[ "$DEBUG" -ge 2 ]]; then
          echo "=== just read banner ==="
          cat <&5 &
     else
          dd of=/dev/null count=8 <&5 2>/dev/null &
     fi
     wait_kill $! $waitsleep
     return 0
}

starttls_full_read(){
     local starttls_read_data=()
     local one_line=""
     local ret=0
     local cont_pattern="$1"
     local end_pattern="$2"
     local ret_found=0

     debugme echo "=== reading banner ... ==="
     if [[ $# -ge 3 ]]; then
          debugme echo "=== we'll have to search for \"$3\" pattern ==="
          ret_found=3
     fi

     local oldIFS="$IFS"
     IFS=''
     while read -r -t $STARTTLS_SLEEP one_line; ret=$?; (exit $ret); do
          debugme echo "S: ${one_line}"
          if [[ $# -ge 3 ]]; then
               if [[ ${one_line} =~ $3 ]]; then
                    ret_found=0
                    debugme echo "^^^^^^^ that's what we were looking for ==="
               fi
          fi
          starttls_read_data+=("${one_line}")
          if [[ $DEBUG -ge 4 ]]; then
               echo "one_line: ${one_line}"
               echo "end_pattern: ${end_pattern}"
               echo "cont_pattern: ${cont_pattern}"
          fi
          if [[ ${one_line} =~ ${end_pattern} ]]; then
               debugme echo "=== full read finished ==="
               IFS="${oldIFS}"
               return ${ret_found}
          fi
          if [[ ! ${one_line} =~ ${cont_pattern} ]]; then
               debugme echo "=== full read syntax error, expected regex pattern ${cont_pattern} (cont) or ${end_pattern} (end) ==="
               IFS="${oldIFS}"
               return 2
          fi
     done <&5
     if [[ $DEBUG -ge 2 ]]; then
          if [[ $ret -ge 128 ]]; then
               echo "=== timeout reading ==="
          else
               echo "=== full read error (no timeout) ==="
          fi
     fi
     IFS="${oldIFS}"
     return $ret
}

starttls_ftp_dialog() {
     debugme echo "=== starting ftp STARTTLS dialog ==="
     local reAUTHTLS='^ AUTH TLS'
     starttls_full_read '^220-' '^220 '                    && debugme echo "received server greeting" &&
     starttls_just_send 'FEAT'                             && debugme echo "sent FEAT" &&
     starttls_full_read '^(211-| )' '^211 ' "${reAUTHTLS}" && debugme echo "received server features and checked STARTTLS availability" &&
     starttls_just_send 'AUTH TLS'                         && debugme echo "initiated STARTTLS" &&
     starttls_full_read '^234-' '^234 '                    && debugme echo "received ack for STARTTLS"
     local ret=$?
     debugme echo "=== finished ftp STARTTLS dialog with ${ret} ==="
     return $ret
}

# argv1: empty: SMTP, "lmtp" : LMTP
#
starttls_smtp_dialog() {
     local greet_str="EHLO"
     local proto="smtp"

     if [[ "$1" == lmtp ]]; then
          proto="lmtp"
          greet_str="LHLO"
     fi
     debugme echo "=== starting $proto STARTTLS dialog ==="

     local re250STARTTLS='^250[ -]STARTTLS'
     starttls_full_read '^220-' '^220 '                    && debugme echo "received server greeting" &&
     starttls_just_send "$greet_str testssl.sh"            && debugme echo "sent $greet_str" &&
     starttls_full_read '^250-' '^250 ' "${re250STARTTLS}" && debugme echo "received server capabilities and checked STARTTLS availability" &&
     starttls_just_send 'STARTTLS'                         && debugme echo "initiated STARTTLS" &&
     starttls_full_read '^220-' '^220 '                    && debugme echo "received ack for STARTTLS"
     local ret=$?
     debugme echo "=== finished $proto STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_pop3_dialog() {
     debugme echo "=== starting pop3 STARTTLS dialog ==="
     starttls_full_read '^\+OK' '^\+OK'                    && debugme echo "received server greeting" &&
     starttls_just_send 'STLS'                             && debugme echo "initiated STARTTLS" &&
     starttls_full_read '^\+OK' '^\+OK'                    && debugme echo "received ack for STARTTLS"
     local ret=$?
     debugme echo "=== finished pop3 STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_imap_dialog() {
     debugme echo "=== starting imap STARTTLS dialog ==="
     local reSTARTTLS='^\* CAPABILITY(( .*)? IMAP4rev1( .*)? STARTTLS(.*)?|( .*)? STARTTLS( .*)? IMAP4rev1(.*)?)$'
     starttls_full_read '^\* ' '^\* OK '                   && debugme echo "received server greeting" &&
     starttls_just_send 'a001 CAPABILITY'                  && debugme echo "sent CAPABILITY" &&
     starttls_full_read '^\* ' '^a001 OK ' "${reSTARTTLS}" && debugme echo "received server capabilities and checked STARTTLS availability" &&
     starttls_just_send 'a002 STARTTLS'                    && debugme echo "initiated STARTTLS" &&
     starttls_full_read '^\* ' '^a002 OK '                 && debugme echo "received ack for STARTTLS"
     local ret=$?
     debugme echo "=== finished imap STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_xmpp_dialog() {
     debugme echo "=== starting imap XMPP dialog ==="
     [[ -z $XMPP_HOST ]] && XMPP_HOST="$NODE"

     starttls_io "<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client' to='"$XMPP_HOST"' version='1.0'>"  'starttls(.*)features'  1 &&
     starttls_io "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"  '<proceed'  1
     local ret=$?
     debugme echo "=== finished XMPP STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_nntp_dialog() {
     debugme echo "=== starting nntp STARTTLS dialog ==="
     starttls_full_read '$^' '^20[01] '                    && debugme echo "received server greeting" &&
     starttls_just_send 'STARTTLS'                         && debugme echo "initiated STARTTLS" &&
     starttls_full_read '$^' '^382 '                       && debugme echo "received ack for STARTTLS"
     local ret=$?
     debugme echo "=== finished nntp STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_postgres_dialog() {
     debugme echo "=== starting postgres STARTTLS dialog ==="
     local init_tls=", x00, x00 ,x00 ,x08 ,x04 ,xD2 ,x16 ,x2F"
     socksend "${init_tls}" 0                               && debugme echo "initiated STARTTLS" &&
     starttls_io "" S 1                                     && debugme echo "received ack (="S") for STARTTLS"
     local ret=$?
     debugme echo "=== finished postgres STARTTLS dialog with ${ret} ==="
     return $ret
}

starttls_mysql_dialog() {
     debugme echo "=== starting mysql STARTTLS dialog ==="
     local login_request="
     , x20, x00, x00, x01,                   # payload_length, sequence_id
     x85, xae, xff, x00,                     # capability flags, CLIENT_SSL always set
     x00, x00, x00, x01,                     # max-packet size
     x21,                                    # character set
     x00, x00, x00, x00, x00, x00, x00, x00, # string[23] reserved (all [0])
     x00, x00, x00, x00, x00, x00, x00, x00,
     x00, x00, x00, x00, x00, x00, x00"
     socksend "${login_request}" 0
     starttls_just_read 1                    && debugme echo "read succeeded"
     # 1 is the timeout value which only MySQL needs. Note, there seems no response whether STARTTLS
     # succeeded. We could try harder, see https://github.com/openssl/openssl/blob/master/apps/s_client.c
     # but atm this seems sufficient as later we will fail if there's no STARTTLS.
     # BUT: there seeem to be cases when the handshake fails (8S01Bad handshake --> 30 38 53 30 31 42 61 64 20 68 61 6e 64 73 68 61 6b 65).
     #      also there's a banner in the reply "<version><somebytes>mysql_native_password"
     # TODO: We could detect if the server supports STARTTLS via the "Server Capabilities"
     # bit field, but we'd need to parse the binary stream, with greater precision than regex.
     local ret=$?
     debugme echo "=== finished mysql STARTTLS dialog with ${ret} ==="
     return $ret
}

# arg1: fd for socket -- which we don't use as it is a hassle and it is not clear whether it works under every bash version
# returns 6 if opening the socket caused a problem, 1 if STARTTLS handshake failed, 0: all ok
#
fd_socket() {
     local jabber=""
     local proyxline=""
     local nodeip="$(tr -d '[]' <<< $NODEIP)"          # sockets do not need the square brackets we have of IPv6 addresses
                                                       # we just need do it here, that's all!
     if [[ -t 5 ]]; then
          pr_warning "$PROG_NAME: unable to open a socket because of a tty conflict"
          return 6
     fi
     if [[ -n "$PROXY" ]]; then
          # PROXYNODE works better than PROXYIP on modern versions of squid
          if ! exec 5<> /dev/tcp/${PROXYNODE}/${PROXYPORT}; then
               outln
               pr_warning "$PROG_NAME: unable to open a socket to proxy $PROXYNODE:$PROXYPORT"
               return 6
          fi
          if "$DNS_VIA_PROXY"; then
               printf -- "%b" "CONNECT $NODE:$PORT HTTP/1.0\n\n" >&5
          else
               printf -- "%b" "CONNECT $nodeip:$PORT HTTP/1.0\n\n" >&5
          fi
          while true; do
               read -t $PROXY_WAIT -r proyxline <&5
               if [[ $? -ge 128 ]]; then
                    pr_warning "Proxy timed out. Unable to CONNECT via proxy. "
                    close_socket
                    return 6
               elif [[ "${proyxline%/*}" == HTTP ]]; then
                    proyxline=${proyxline#* }
                    if [[ "${proyxline%% *}" != 200 ]]; then
                         pr_warning "Unable to CONNECT via proxy. "
                         [[ "$PORT" != 443 ]] && prln_warning "Check whether your proxy supports port $PORT and the underlying protocol."
                         close_socket
                         return 6
                    fi
               fi
               if [[ "$proyxline" == $'\r' ]] || [[ -z "$proyxline" ]] ; then
                    break
               fi
          done
     elif ! exec 5<>/dev/tcp/$nodeip/$PORT; then  #  2>/dev/null would remove an error message, but disables debugging
          ((NR_SOCKET_FAIL++))
          connectivity_problem $NR_SOCKET_FAIL $MAX_SOCKET_FAIL "TCP connect problem" "repeated TCP connect problems, giving up"
          outln
          pr_warning "Unable to open a socket to $NODEIP:$PORT. "
          # It can last ~2 minutes but for for those rare occasions we don't do a timeout handler here, KISS
          return 6
     fi

     if [[ -n "$STARTTLS" ]]; then
          case "$STARTTLS_PROTOCOL" in # port
               ftp|ftps)   # https://tools.ietf.org/html/rfc4217, https://tools.ietf.org/html/rfc959
                    starttls_ftp_dialog
                    ;;
               smtp|smtps) # SMTP, see https://tools.ietf.org/html/rfc{2033,3207,5321}
                    starttls_smtp_dialog
                    ;;
               lmtp|lmtps) # LMTP, see https://tools.ietf.org/html/rfc{2033,3207,5321}
                    starttls_smtp_dialog lmtp
                    ;;
               pop3|pop3s) # POP, see https://tools.ietf.org/html/rfc2595
                    starttls_pop3_dialog
                    ;;
               nntp|nntps) # NNTP, see https://tools.ietf.org/html/rfc4642
                    starttls_nntp_dialog
                    ;;
               imap|imaps) # IMAP, https://tools.ietf.org/html/rfc2595, https://tools.ietf.org/html/rfc3501
                    starttls_imap_dialog
                    ;;
               irc|ircs) # IRC, https://ircv3.net/specs/extensions/tls-3.1.html, https://ircv3.net/specs/core/capability-negotiation.html
                    fatal "FIXME: IRC+STARTTLS not yet supported" $ERR_NOSUPPORT
                    ;;
               ldap|ldaps) # LDAP, https://tools.ietf.org/html/rfc2830, https://tools.ietf.org/html/rfc4511
                    fatal "FIXME: LDAP+STARTTLS over sockets not supported yet (try \"--ssl-native\")" $ERR_NOSUPPORT
                    ;;
               acap|acaps) # ACAP = Application Configuration Access Protocol, see https://tools.ietf.org/html/rfc2595
                    fatal "ACAP Easteregg: not implemented -- probably never will" $ERR_NOSUPPORT
                    ;;
               xmpp|xmpps) # XMPP, see https://tools.ietf.org/html/rfc6120
                    starttls_xmpp_dialog
                   # IM observatory: https://xmpp.net , XMPP server directory: https://xmpp.net/directory.php
                    ;;
               postgres) # Postgres SQL, see http://www.postgresql.org/docs/devel/static/protocol-message-formats.html
                    starttls_postgres_dialog
                    ;;
               mysql) # MySQL, see https://dev.mysql.com/doc/internals/en/x-protocol-lifecycle-lifecycle.html#x-protocol-lifecycle-tls-extension
                    starttls_mysql_dialog
                    ;;
               *) # we need to throw an error here -- otherwise testssl.sh treats the STARTTLS protocol as plain SSL/TLS which leads to FP
                    fatal "FIXME: STARTTLS protocol $STARTTLS_PROTOCOL is not yet supported" $ERR_NOSUPPORT
          esac
     fi
     [[ $? -eq 0 ]] && return 0
     prln_warning " STARTTLS handshake failed"
     return 1
}

close_socket(){
     exec 5<&-
     exec 5>&-
     return 0
}

send_close_notify() {
     local detected_tlsversion="$1"

     debugme echo "sending close_notify..."
     if [[ $detected_tlsversion == 0300 ]]; then
          socksend ",x15, x03, x00, x00, x02, x02, x00" 0
     else
          socksend ",x15, x03, x01, x00, x02, x02, x00" 0
     fi
}

# Format string properly for socket
# ARG1: any commented sequence of two bytes hex, separated by commas. It can contain comments, new lines, tabs and white spaces
# NW_STR holds the global with the string prepared for printf, like '\x16\x03\x03\'
code2network() {
     NW_STR=$(sed -e 's/,/\\\x/g' <<< "$1" | sed -e 's/# .*$//g' -e 's/ //g' -e '/^$/d' | tr -d '\n' | tr -d '\t')
}

# sockets inspired by http://blog.chris007.de/?p=238
# ARG1: hexbytes separated by commas, with a leading comma
# ARG2: seconds to sleep
socksend_clienthello() {
     local data=""

     code2network "$1"
     data="$NW_STR"
     [[ "$DEBUG" -ge 4 ]] && echo && echo "\"$data\""
     if [[ -z "$PRINTF" ]] ;then
          # We could also use "dd ibs=1M obs=1M" here but is seems to be at max 3% slower
          printf -- "$data" | cat >&5 2>/dev/null &
     else
          $PRINTF -- "$data" 2>/dev/null >&5 2>/dev/null &
     fi
     sleep $USLEEP_SND
}


# ARG1: hexbytes -- preceeded by x -- separated by commas, with a leading comma
# ARG2: seconds to sleep
socksend() {
     local data line

     # read line per line and strip comments (bash internal func can't handle multiline statements
     data="$(while read line; do
          printf "${line%%\#*}"
     done <<< "$1" )"
     data="${data// /}"       # strip ' '
     data="${data//,/\\}"     # s&r , by \
     [[ $DEBUG -ge 4 ]] && echo && echo "\"$data\""
     if [[ -z "$PRINTF" ]] ;then
          printf -- "$data" | cat >&5 2>/dev/null &
     else
          $PRINTF -- "$data" 2>/dev/null >&5 2>/dev/null &
     fi
     sleep $2
}


# for SSLv2 to TLS 1.2:
# ARG1: blocksize for reading
sockread_serverhello() {
     [[ -z "$2" ]] && maxsleep=$MAX_WAITSOCK || maxsleep=$2
     SOCK_REPLY_FILE=$(mktemp $TEMPDIR/ddreply.XXXXXX) || return 7
     dd bs=$1 of=$SOCK_REPLY_FILE count=1 <&5 2>/dev/null &
     wait_kill $! $maxsleep
     return $?
}

#trying a faster version
# ARG1: blocksize for reading
sockread_fast() {
     dd bs=$1 count=1 <&5 2>/dev/null | hexdump -v -e '16/1 "%02X"'
}

len2twobytes() {
     local len_arg1=${#1}
     [[ $len_arg1 -le 2 ]] && LEN_STR=$(printf "00, %02s \n" "$1")
     [[ $len_arg1 -eq 3 ]] && LEN_STR=$(printf "0%s, %02s \n" "${1:0:1}" "${1:1:2}")
     [[ $len_arg1 -eq 4 ]] && LEN_STR=$(printf "%02s, %02s \n" "${1:0:2}" "${1:2:2}")
}


get_pub_key_size() {
     local pubkey pubkeybits
     local -i i len1 len

     "$HAS_PKEY" || return 1

     # OpenSSL displays the number of bits for RSA and ECC
     pubkeybits=$($OPENSSL x509 -noout -pubkey -in $HOSTCERT 2>>$ERRFILE | $OPENSSL pkey -pubin -text 2>>$ERRFILE | grep -aw "Public-Key:" | sed -e 's/.*(//' -e 's/)//')
     if [[ -n $pubkeybits ]]; then
          echo "Server public key is $pubkeybits" >> $TMPFILE
     else
          # This extracts the public key for DSA, DH, and GOST
          pubkey=$($OPENSSL x509 -noout -pubkey -in $HOSTCERT 2>>$ERRFILE | $OPENSSL pkey -pubin -outform DER 2>>$ERRFILE | hexdump -v -e '16/1 "%02X"')
          [[ -z "$pubkey" ]] && return 1
          # Skip over tag and length of subjectPublicKeyInfo
          i=2
          len1="0x${pubkey:i:2}"
          if [[ $len1 -lt 0x80 ]]; then
               i=$i+2
          else
               len1=$len1-0x80
               i=$i+2*$len1+2
          fi

          # Skip over algorithm field
          i=$i+2
          len1="0x${pubkey:i:2}"
          i=$i+2
          if [[ $len1 -lt 0x80 ]]; then
               i=$i+2*$len1
          else
               case $len1 in
                    129) len="0x${pubkey:i:2}" ;;
                    130) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        ;;
                    131) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        ;;
                    132) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        ;;
               esac
               i=$i+2+2*$len
          fi

          # Next is the public key BIT STRING. Skip over tag, length, and number of unused bits.
          i=$i+2
          len1="0x${pubkey:i:2}"
          if [[ $len1 -lt 0x80 ]]; then
               i=$i+4
          else
               len1=$len1-0x80
               i=$i+2*$len1+4
          fi

          # Now get the length of the public key
          i=$i+2
          len1="0x${pubkey:i:2}"
          i=$i+2
          if [[ $len1 -lt 0x80 ]]; then
               len=$len1
          else
               case $len1 in
                    129) len="0x${pubkey:i:2}" ;;
                    130) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        ;;
                    131) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*$len+"0x${pubkey:i:2}"
                        ;;
                    132) len="0x${pubkey:i:2}"
                        i=$i+2
                        len=256*"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*"0x${pubkey:i:2}"
                        i=$i+2
                        len=256*"0x${pubkey:i:2}"
                        ;;
               esac
          fi
          len=8*$len # convert from bytes to bits
          pubkeybits="$(printf "%d" $len)"
          echo "Server public key is $pubkeybits bit" >> $TMPFILE
     fi
     return 0
}

# Extract the DH ephemeral key from the ServerKeyExchange message
get_dh_ephemeralkey() {
     local tls_serverkeyexchange_ascii="$1"
     local -i tls_serverkeyexchange_ascii_len offset
     local dh_p dh_g dh_y dh_param len1 key_bitstring
     local -i i dh_p_len dh_g_len dh_y_len dh_param_len

     "$HAS_PKEY" || return 1

     tls_serverkeyexchange_ascii_len=${#tls_serverkeyexchange_ascii}
     dh_p_len=2*$(hex2dec "${tls_serverkeyexchange_ascii:0:4}")
     offset=4+$dh_p_len
     if [[ $tls_serverkeyexchange_ascii_len -lt $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi

     # Subtract any leading 0 bytes
     for (( i=4; i < offset; i=i+2 )); do
          [[ "${tls_serverkeyexchange_ascii:i:2}" != "00" ]] && break
          dh_p_len=$dh_p_len-2
     done
     if [[ $i -ge $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     dh_p="${tls_serverkeyexchange_ascii:i:dh_p_len}"

     dh_g_len=2*$(hex2dec "${tls_serverkeyexchange_ascii:offset:4}")
     i=4+$offset
     offset+=4+$dh_g_len
     if [[ $tls_serverkeyexchange_ascii_len -lt $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     # Subtract any leading 0 bytes
     for (( 1; i < offset; i=i+2 )); do
          [[ "${tls_serverkeyexchange_ascii:i:2}" != "00" ]] && break
          dh_g_len=$dh_g_len-2
     done
     if [[ $i -ge $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     dh_g="${tls_serverkeyexchange_ascii:i:dh_g_len}"

     dh_y_len=2*$(hex2dec "${tls_serverkeyexchange_ascii:offset:4}")
     i=4+$offset
     offset+=4+$dh_y_len
     if [[ $tls_serverkeyexchange_ascii_len -lt $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     # Subtract any leading 0 bytes
     for (( 1; i < offset; i=i+2 )); do
          [[ "${tls_serverkeyexchange_ascii:i:2}" != "00" ]] && break
          dh_y_len=$dh_y_len-2
     done
     if [[ $i -ge $offset ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     dh_y="${tls_serverkeyexchange_ascii:i:dh_y_len}"

     # The following code assumes that all lengths can be encoded using at most 2 bytes,
     # which just means that the encoded length of the public key must be less than
     # 65,536 bytes. If the length is anywhere close to that, it is almost certainly an
     # encoding error.
     if [[ $dh_p_len+$dh_g_len+$dh_y_len -ge 131000 ]]; then
          debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
          return 1
     fi
     # make ASN.1 INTEGER of p, g, and Y
     [[ "0x${dh_p:0:1}" -ge 8 ]] && dh_p_len+=2 && dh_p="00$dh_p"
     if [[ $dh_p_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_p_len/2)))"
     elif [[ $dh_p_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_p_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_p_len/2)))"
     fi
     dh_p="02${len1}$dh_p"

     [[ "0x${dh_g:0:1}" -ge 8 ]] && dh_g_len+=2 && dh_g="00$dh_g"
     if [[ $dh_g_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_g_len/2)))"
     elif [[ $dh_g_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_g_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_g_len/2)))"
     fi
     dh_g="02${len1}$dh_g"

     [[ "0x${dh_y:0:1}" -ge 8 ]] && dh_y_len+=2 && dh_y="00$dh_y"
     if [[ $dh_y_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_y_len/2)))"
     elif [[ $dh_y_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_y_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_y_len/2)))"
     fi
     dh_y="02${len1}$dh_y"

     # Make a SEQUENCE of p and g
     dh_param_len=${#dh_p}+${#dh_g}
     if [[ $dh_param_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_param_len/2)))"
     elif [[ $dh_param_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_param_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_param_len/2)))"
     fi
     dh_param="30${len1}${dh_p}${dh_g}"

     # Make a SEQUENCE of the parameters SEQUENCE and the OID
     dh_param_len=22+${#dh_param}
     if [[ $dh_param_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_param_len/2)))"
     elif [[ $dh_param_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_param_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_param_len/2)))"
     fi
     dh_param="30${len1}06092A864886F70D010301${dh_param}"

     # Encapsulate public key, y, in a BIT STRING
     dh_y_len=${#dh_y}+2
     if [[ $dh_y_len -lt 256 ]]; then
          len1="$(printf "%02x" $((dh_y_len/2)))"
     elif [[ $dh_y_len -lt 512 ]]; then
          len1="81$(printf "%02x" $((dh_y_len/2)))"
     else
          len1="82$(printf "%04x" $((dh_y_len/2)))"
     fi
     dh_y="03${len1}00$dh_y"

     # Create the public key SEQUENCE
     i=${#dh_param}+${#dh_y}
     if [[ $i -lt 256 ]]; then
          len1="$(printf "%02x" $((i/2)))"
     elif [[ $i -lt 512 ]]; then
          len1="81$(printf "%02x" $((i/2)))"
     else
          len1="82$(printf "%04x" $((i/2)))"
     fi
     key_bitstring="30${len1}${dh_param}${dh_y}"
     key_bitstring="$(asciihex_to_binary_file "$key_bitstring" "/dev/stdout" | $OPENSSL pkey -pubin -inform DER 2> $ERRFILE)"
     [[ -z "$key_bitstring" ]] && return 1
     tm_out "$key_bitstring"
     return 0
}

# arg1: name of file with socket reply
# arg2: true if entire server hello should be parsed
# return values: 0=no SSLv2 (reset)
#                1=no SSLv2 (plaintext reply like it happens with OLS webservers)
#                3=SSLv2 supported (in $TEMPDIR/$NODEIP.sslv2_sockets.dd is reply for further processing
#                  --> there could be checked whether ciphers e.g have been returned at all (or anything else)
#                4=looks like an STARTTLS 5xx message
#                6=socket couldn't be opened
#                7=strange reply we can't deal with
parse_sslv2_serverhello() {
     local ret v2_hello_ascii v2_hello_initbyte v2_hello_length
     local v2_hello_handshake v2_cert_type v2_hello_cert_length
     local v2_hello_cipherspec_length
     local -i certificate_len nr_ciphers_detected offset i
     local ret=3
     local parse_complete="false"
     # SSLv2 server hello:                                             in hex representation, see below
     # byte 1+2: length of server hello                          0123
     # 3:        04=Handshake message, server hello              45
     # 4:        session id hit or not (boolean: 00=false, this  67
     #           is the normal case)
     # 5:        certificate type, 01 = x509                     89
     # 6+7       version (00 02 = SSLv2)                         10-13
     # 8+9       certificate length                              14-17
     # 10+11     cipher spec length                              17-20
     # 12+13     connection id length
     # [certificate length] ==> certificate
     # [cipher spec length] ==> ciphers GOOD: HERE ARE ALL CIPHERS ALREADY!

     # Note: recent SSL/TLS stacks reply with a TLS alert on a SSLv2 client hello.
     # The TLS error message is different and could be used for fingerprinting.

     if [[ "$2" == "true" ]]; then
          parse_complete=true
     fi
     "$parse_complete" && echo "======================================" > $TMPFILE

     v2_hello_ascii=$(hexdump -v -e '16/1 "%02X"' $1)
     v2_hello_ascii="${v2_hello_ascii%%[!0-9A-F]*}"
     [[ "$DEBUG" -ge 5 ]] && echo "$v2_hello_ascii"
     if [[ -z "$v2_hello_ascii" ]]; then
          ret=0                                      # 1 line without any blanks: no server hello received
          debugme echo "server hello empty"
     else
          # now scrape two bytes out of the reply per byte
          v2_hello_initbyte="${v2_hello_ascii:0:1}"  # normally this belongs to the next, should be 8!
          v2_hello_length="${v2_hello_ascii:1:3}"    # + 0x8000 see above
          v2_hello_handshake="${v2_hello_ascii:4:2}"
          v2_cert_type="${v2_hello_ascii:8:2}"
          v2_hello_cert_length="${v2_hello_ascii:14:4}"
          v2_hello_cipherspec_length="${v2_hello_ascii:18:4}"

          V2_HELLO_CIPHERSPEC_LENGTH=$(printf "%d\n" "0x$v2_hello_cipherspec_length" 2>/dev/null)
          [[ $? -ne 0 ]] && ret=7

          if [[ "${v2_hello_ascii:0:2}" == "35" ]] && "$do_starttls"; then
               # this could be a 500/5xx for some weird reason where the STARTTLS handshake failed
               debugme echo "$(hex2ascii "$v2_hello_ascii")"
               ret=4
          elif [[ "${v2_hello_ascii:0:4}" == "1503" ]]; then
               # Cloudflare does this, OpenSSL 1.1.1 and picoTLS. With different alert messages
               # Just in case somebody's interested in the exact error, we deliver it ;-)
               debugme echo -n ">TLS< alert message discovered: ${v2_hello_ascii} "
               case "${v2_hello_ascii:10:2}" in
                    01) debugme echo "(01/warning: 0x"${v2_hello_ascii:12:2}"/$(tls_alert "${v2_hello_ascii:12:2}"))" ;;
                    02) debugme echo "(02/fatal: 0x"${v2_hello_ascii:12:2}"/$(tls_alert "${v2_hello_ascii:12:2}"))" ;;
                    *)  debugme echo "("${v2_hello_ascii:10:2}" : "${v2_hello_ascii:12:2}"))" ;;
               esac
               ret=0
          elif [[ $v2_hello_initbyte != "8" ]] || [[ $v2_hello_handshake != "04" ]]; then
               ret=1
               if [[ $DEBUG -ge 2 ]]; then
                    echo "no correct server hello"
                    echo "SSLv2 server init byte:    0x0$v2_hello_initbyte"
                    echo "SSLv2 hello handshake :    0x$v2_hello_handshake"
               fi
          fi

          if [[ $DEBUG -ge 3 ]]; then
               echo "SSLv2 server hello length: 0x0$v2_hello_length"
               echo "SSLv2 certificate type:    0x$v2_cert_type"
               echo "SSLv2 certificate length:  0x$v2_hello_cert_length"
               echo "SSLv2 cipher spec length:  0x$v2_hello_cipherspec_length"
          fi

          if "$parse_complete" && [[ 2*$(hex2dec "$v2_hello_length") -ne ${#v2_hello_ascii}-4 ]]; then
               ret=7
          fi
     fi

     "$parse_complete" || return $ret

     # not sure why we need this
     rm -f $HOSTCERT
     > $TEMPDIR/intermediatecerts.pem
     if [[ $ret -eq 3 ]]; then
          certificate_len=2*$(hex2dec "$v2_hello_cert_length")

          if [[ "$v2_cert_type" == "01" ]] && [[ "$v2_hello_cert_length" != "00" ]]; then
               asciihex_to_binary_file "${v2_hello_ascii:26:certificate_len}" "/dev/stdout" | \
                    $OPENSSL x509 -inform DER -outform PEM -out $HOSTCERT 2>$ERRFILE
               if [[ $? -ne 0 ]]; then
                    debugme echo "Malformed certificate in ServerHello."
                    return 1
               fi
               get_pub_key_size
               echo "======================================" >> $TMPFILE
          fi

          # Output list of supported ciphers
          offset=$((certificate_len+26))
          nr_ciphers_detected=$((V2_HELLO_CIPHERSPEC_LENGTH / 3))
          for (( i=0 ; i<nr_ciphers_detected; i++ )); do
               echo "Supported cipher: x$(tolower "${v2_hello_ascii:offset:6}")" >> $TMPFILE
               offset=$((offset+6))
          done
          echo "======================================" >> $TMPFILE

          tmpfile_handle ${FUNCNAME[0]}.txt
     fi
     return $ret
}

# arg1: hash function
# arg2: key
# arg3: text
hmac() {
     local hash_fn="$1"
     local key="$2" text="$3" output
     local -i ret

     if [[ ! "$OSSL_NAME" =~ LibreSSL ]] && [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 3.0.0* ]]; then
          output="$(asciihex_to_binary_file "$text" "/dev/stdout" | $OPENSSL mac -macopt digest:"${hash_fn/-/}" -macopt hexkey:"$key" HMAC 2>/dev/null)"
          ret=$?
          tm_out "$(strip_lf "$output")"
     else
          output="$(asciihex_to_binary_file "$text" "/dev/stdout" | $OPENSSL dgst "$hash_fn" -mac HMAC -macopt hexkey:"$key" 2>/dev/null)"
          ret=$?
          tm_out "$(awk  '/=/ { print $2 }' <<< "$output")"
     fi
     return $ret
}

# arg1: hash function
# arg2: pseudorandom key (PRK)
# arg2: info
# arg3: length of output keying material in octets
# See RFC 5869, Section 2.3
hkdf-expand() {
     local hash_fn="$1"
     local prk="$2" info="$3" output=""
     local -i out_len="$4"
     local -i i n mod_check hash_len ret
     local counter
     local ti tim1 # T(i) and T(i-1)

     case "$hash_fn" in
          "-sha256") hash_len=32 ;;
          "-sha384") hash_len=48 ;;
          *) return 7
     esac

     n=$out_len/$hash_len
     mod_check=$out_len%$hash_len
     [[ $mod_check -ne 0 ]] && n+=1

     tim1=""
     for (( i=1; i <= n; i++ )); do
          counter="$(printf "%02X\n" $i)"
          ti="$(hmac "$hash_fn" "$prk" "$tim1$info$counter")"
          [[ $? -ne 0 ]] && return 7
          output+="$ti"
          tim1="$ti"
     done
     out_len=2*$out_len
     tm_out "${output:0:out_len}"
     return 0
}

# arg1: hash function
# arg2: secret
# arg3: label
# arg4: context
# arg5: length
# See RFC 8446, Section 7.1
hkdf-expand-label() {
     local hash_fn="$1"
     local secret="$2" label="$3"
     local context="$4"
     local -i length="$5"
     local hkdflabel hkdflabel_label hkdflabel_context
     local hkdflabel_length
     local -i len

     hkdflabel_length="$(printf "%04X\n" $length)"
     if [[ "${TLS_SERVER_HELLO:8:2}" == "7F" ]] && [[ 0x${TLS_SERVER_HELLO:10:2} -lt 0x14 ]]; then
          # "544c5320312e332c20" = "TLS 1.3, "
          hkdflabel_label="544c5320312e332c20$label"
     else
          # "746c73313320" = "tls13 "
          hkdflabel_label="746c73313320$label"
     fi
     len=${#hkdflabel_label}/2
     hkdflabel_label="$(printf "%02X\n" $len)$hkdflabel_label"
     len=${#context}/2
     hkdflabel_context="$(printf "%02X\n" $len)$context"
     hkdflabel="$hkdflabel_length$hkdflabel_label$hkdflabel_context"

     hkdf-expand "$hash_fn" "$secret" "$hkdflabel" "$length"
     return $?
}

# arg1: hash function
# arg2: secret
# arg3: label
# arg4: ASCII-HEX of messages
# See RFC 8446, Section 7.1
derive-secret() {
     local hash_fn="$1"
     local secret="$2" label="$3" messages="$4"
     local hash_messages
     local -i hash_len retcode

     case "$hash_fn" in
          "-sha256") hash_len=32 ;;
          "-sha384") hash_len=48 ;;
          *) return 7
     esac

     hash_messages="$(asciihex_to_binary_file "$messages" "/dev/stdout" | $OPENSSL dgst "$hash_fn" 2>/dev/null | awk  '/=/ { print $2 }')"
     hkdf-expand-label "$hash_fn" "$secret" "$label" "$hash_messages" "$hash_len"
     return $?
}

# arg1: hash function
# arg2: private key file
# arg3: file containing server's ephemeral public key
# arg4: ASCII-HEX of messages (ClientHello...ServerHello)
# See key derivation schedule diagram in Section 7.1 of RFC 8446
derive-handshake-traffic-secret() {
     local hash_fn="$1"
     local priv_file="$2" pub_file="$3"
     local messages="$4"
     local -i i ret
     local early_secret derived_secret shared_secret handshake_secret

     "$HAS_PKUTIL" || return 1

     # early_secret="$(hmac "$hash_fn" "000...000" "000...000")"
     case "$hash_fn" in
          "-sha256") early_secret="33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"
                     if [[ "${TLS_SERVER_HELLO:8:2}" == "7F" ]] && [[ 0x${TLS_SERVER_HELLO:10:2} -lt 0x14 ]]; then
                          # "6465726976656420736563726574" = "derived secret"
                          # derived_secret="$(derive-secret "$hash_fn" "$early_secret" "6465726976656420736563726574" "")"
                          derived_secret="c1c0c36bf8fb1d1afa949fbd360e71af69a6244a4c2eaef5bbbb6442a7277d2c"
                     else
                          # "64657269766564" = "derived"
                          # derived_secret="$(derive-secret "$hash_fn" "$early_secret" "64657269766564" "")"
                          derived_secret="6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"
                     fi
                     ;;
          "-sha384") early_secret="7ee8206f5570023e6dc7519eb1073bc4e791ad37b5c382aa10ba18e2357e716971f9362f2c2fe2a76bfd78dfec4ea9b5"
                     if [[ "${TLS_SERVER_HELLO:8:2}" == "7F" ]] && [[ 0x${TLS_SERVER_HELLO:10:2} -lt 0x14 ]]; then
                           # "6465726976656420736563726574" = "derived secret"
                           # derived_secret="$(derive-secret "$hash_fn" "$early_secret" "6465726976656420736563726574" "")"
                          derived_secret="54c80fa05ee9e0532ce3db8ddeca37a0365683bcd3b27bdc88d2b9fdc115ca4ebc8edc1f0b72a6a0861e803fc34761ef"
                     else
                          # "64657269766564" = "derived"
                          # derived_secret="$(derive-secret "$hash_fn" "$early_secret" "64657269766564" "")"
                          derived_secret="1591dac5cbbf0330a4a84de9c753330e92d01f0a88214b4464972fd668049e93e52f2b16fad922fdc0584478428f282b"
                     fi
                     ;;
          *) return 7
     esac

     shared_secret="$($OPENSSL pkeyutl -derive -inkey "$priv_file" -peerkey "$pub_file" 2>/dev/null | hexdump -v -e '16/1 "%02X"')"

     # For draft 18 use $early_secret rather than $derived_secret.
     if [[ "${TLS_SERVER_HELLO:8:4}" == "7F12" ]]; then
          handshake_secret="$(hmac "$hash_fn" "$early_secret" "${shared_secret%%[!0-9A-F]*}")"
     else
          handshake_secret="$(hmac "$hash_fn" "$derived_secret" "${shared_secret%%[!0-9A-F]*}")"
     fi
     [[ $? -ne 0 ]] && return 7

     if [[ "${TLS_SERVER_HELLO:8:2}" == "7F" ]] && [[ 0x${TLS_SERVER_HELLO:10:2} -lt 0x14 ]]; then
          # "7365727665722068616e647368616b65207472616666696320736563726574" = "server handshake traffic secret"
          derived_secret="$(derive-secret "$hash_fn" "$handshake_secret" "7365727665722068616e647368616b65207472616666696320736563726574" "$messages")"
     else
          # "732068732074726166666963" = "s hs traffic"
          derived_secret="$(derive-secret "$hash_fn" "$handshake_secret" "732068732074726166666963" "$messages")"
     fi
     [[ $? -ne 0 ]] && return 7
     tm_out "$derived_secret"
     return 0
}

# arg1: hash function
# arg2: secret (created by derive-handshake-traffic-secret)
# arg3: purpose ("key" or "iv")
# arg4: length of the key
# See RFC 8446, Section 7.3
derive-traffic-key() {
     local hash_fn="$1"
     local secret="$2" purpose="$3"
     local -i key_length="$4"
     local key

     key="$(hkdf-expand-label "$hash_fn" "$secret" "$purpose" "" "$key_length")"
     [[ $? -ne 0 ]] && return 7
     tm_out "$key"
     return 0
}

#arg1: TLS cipher
#arg2: file containing cipher name, public key, and private key
#arg3: First ClientHello, if response was a HelloRetryRequest
#arg4: HelloRetryRequest, if one was sent
#arg5: Final (or only) ClientHello
#arg6: ServerHello
derive-handshake-traffic-keys() {
     local cipher="$1"
     local tmpfile="$2"
     local clienthello1="$3" hrr="$4" clienthello2="$5" serverhello="$6"
     local hash_clienthello1
     local -i key_len
     local -i retcode
     local hash_fn
     local pub_file priv_file tmpfile

     if [[ "$cipher" == *SHA256 ]]; then
          hash_fn="-sha256"
     elif [[ "$cipher" == *SHA384 ]]; then
          hash_fn="-sha384"
     else
          return 1
     fi
     if [[ "$cipher" == *AES_128* ]]; then
          key_len=16
     elif ( [[ "$cipher" == *AES_256* ]] || [[ "$cipher" == *CHACHA20_POLY1305* ]] ); then
          key_len=32
     else
          return 1
     fi
     pub_file="$(mktemp "$TEMPDIR/pubkey.XXXXXX")" || return 7
     awk '/-----BEGIN PUBLIC KEY/,/-----END PUBLIC KEY/ { print $0 }' \
          "$tmpfile" > "$pub_file"
     [[ ! -s "$pub_file" ]] && return 1

     priv_file="$(mktemp "$TEMPDIR/privkey.XXXXXX")" || return 7
     if grep -q "\-\-\-\-\-BEGIN EC PARAMETERS" "$tmpfile"; then
          awk '/-----BEGIN EC PARAMETERS/,/-----END EC PRIVATE KEY/ { print $0 }' \
               "$tmpfile" > "$priv_file"
     else
          awk '/-----BEGIN PRIVATE KEY/,/-----END PRIVATE KEY/ { print $0 }' \
               "$tmpfile" > "$priv_file"
     fi
     [[ ! -s "$priv_file" ]] && return 1

     if [[ -n "$hrr" ]] && [[ "${serverhello:8:4}" == "7F12" ]]; then
          derived_secret="$(derive-handshake-traffic-secret "$hash_fn" "$priv_file" "$pub_file" "$clienthello1$hrr$clienthello2$serverhello")"
     elif [[ -n "$hrr" ]]; then
          hash_clienthello1="$(asciihex_to_binary_file "$clienthello1" "/dev/stdout" | $OPENSSL dgst "$hash_fn" 2>/dev/null | awk  '/=/ { print $2 }')"
          derived_secret="$(derive-handshake-traffic-secret "$hash_fn" "$priv_file" "$pub_file" "FE0000$(printf "%02x" $((${#hash_clienthello1}/2)))$hash_clienthello1$hrr$clienthello2$serverhello")"
     else
          derived_secret="$(derive-handshake-traffic-secret "$hash_fn" "$priv_file" "$pub_file" "$clienthello2$serverhello")"
     fi
     retcode=$?
     rm $pub_file $priv_file
     [[ $retcode -ne 0 ]] && return 1
     # "6b6579" = "key"
     server_write_key="$(derive-traffic-key "$hash_fn" "$derived_secret" "6b6579" "$key_len")"
     [[ $? -ne 0 ]] && return 1
     # "6976" = "iv"
     server_write_iv="$(derive-traffic-key "$hash_fn" "$derived_secret" "6976" "12")"
     [[ $? -ne 0 ]] && return 1
     tm_out "$server_write_key $server_write_iv"
     return 0
}

generate-ccm-gcm-keystream() {
     local icb="$1" icb_msb icb_lsb1
     local -i i icb_lsb n="$2"

     icb_msb="${icb:0:24}"
     icb_lsb=0x${icb:24:8}

     for (( i=0; i < n; i=i+1 )); do
          icb_lsb1="$(printf "%08X" $icb_lsb)"
          printf "\x${icb_msb:0:2}\x${icb_msb:2:2}\x${icb_msb:4:2}\x${icb_msb:6:2}\x${icb_msb:8:2}\x${icb_msb:10:2}\x${icb_msb:12:2}\x${icb_msb:14:2}\x${icb_msb:16:2}\x${icb_msb:18:2}\x${icb_msb:20:2}\x${icb_msb:22:2}\x${icb_lsb1:0:2}\x${icb_lsb1:2:2}\x${icb_lsb1:4:2}\x${icb_lsb1:6:2}"
          icb_lsb+=1
     done
     return 0
}

# arg1: an OpenSSL ecb cipher (e.g., -aes-128-ecb)
# arg2: key
# arg3: initial counter value (must be 128 bits)
# arg4: ciphertext
# See Sections 6.5 and 7.2 of SP 800-38D and Section 6.2 and Appendix A of SP 800-38C
ccm-gcm-decrypt() {
     local cipher="$1"
     local key="$2"
     local icb="$3"
     local ciphertext="$4"
     local -i i i1 i2 i3 i4
     local -i ciphertext_len n mod_check
     local y plaintext=""

     [[ ${#icb} -ne 32 ]] && return 7

     ciphertext_len=${#ciphertext}
     n=$ciphertext_len/32
     mod_check=$ciphertext_len%32
     [[ $mod_check -ne 0 ]] && n+=1
     y="$(generate-ccm-gcm-keystream "$icb" "$n" | $OPENSSL enc "$cipher" -K "$key" -nopad 2>/dev/null | hexdump -v -e '16/1 "%02X"')"

     # XOR the ciphertext with the keystream ($y). For efficiency, work in blocks of 16 bytes at a time (but with each XOR operation working on
     # 32 bits.
     [[ $mod_check -ne 0 ]] && n=$n-1
     for (( i=0; i < n; i++ )); do
          i1=32*$i; i2=$i1+8; i3=$i1+16; i4=$i1+24
          plaintext+="$(printf "%08X%08X%08X%08X" "$((0x${ciphertext:i1:8} ^ 0x${y:i1:8}))" "$((0x${ciphertext:i2:8} ^ 0x${y:i2:8}))" "$((0x${ciphertext:i3:8} ^ 0x${y:i3:8}))" "$((0x${ciphertext:i4:8} ^ 0x${y:i4:8}))")"
     done
     # If the length of the ciphertext is not an even multiple of 16 bytes, then handle the final incomplete block.
     if [[ $mod_check -ne 0 ]]; then
          i1=32*$n
          for (( i=0; i < mod_check; i=i+2 )); do
               plaintext+="$(printf "%02X" "$((0x${ciphertext:i1:2} ^ 0x${y:i1:2}))")"
               i1+=2
          done
     fi
     tm_out "$plaintext"
     return 0
}

# See RFC 7539, Section 2.1
chacha20_Qround() {
     local -i a="0x$1"
     local -i b="0x$2"
     local -i c="0x$3"
     local -i d="0x$4"
     local -i x y

     a=$(((a+b) & 0xffffffff))
     d=$((d^a))
     # rotate d left 16 bits
     x=$((d & 0xffff0000))
     x=$((x >> 16))
     y=$((d & 0x0000ffff))
     y=$((y << 16))
     d=$((x | y))

     c=$(((c+d) & 0xffffffff))
     b=$((b^c))
     # rotate b left 12 bits
     x=$((b & 0xfff00000))
     x=$((x >> 20))
     y=$((b & 0x000fffff))
     y=$((y << 12))
     b=$((x | y))

     a=$(((a+b) & 0xffffffff))
     d=$((d^a))
     # rotate d left 8 bits
     x=$((d & 0xff000000))
     x=$((x >> 24))
     y=$((d & 0x00ffffff))
     y=$((y << 8))
     d=$((x | y))

     c=$(((c+d) & 0xffffffff))
     b=$((b^c))
     # rotate b left 7 bits
     x=$((b & 0xfe000000))
     x=$((x >> 25))
     y=$((b & 0x01ffffff))
     y=$((y << 7))
     b=$((x | y))

     tm_out "$(printf "%x" $a) $(printf "%x" $b) $(printf "%x" $c) $(printf "%x" $d)"
     return 0
}

# See RFC 7539, Section 2.3.1
chacha20_inner_block() {
     local s0="$1" s1="$2" s2="$3" s3="$4"
     local s4="$5" s5="$6" s6="$7" s7="$8"
     local s8="$9" s9="${10}" s10="${11}" s11="${12}"
     local s12="${13}" s13="${14}" s14="${15}" s15="${16}"
     local res

     res="$(chacha20_Qround "$s0" "$s4" "$s8" "$s12")"
     read -r s0 s4 s8 s12 <<< "$res"
     res="$(chacha20_Qround "$s1" "$s5" "$s9" "$s13")"
     read -r s1 s5 s9 s13 <<< "$res"
     res="$(chacha20_Qround "$s2" "$s6" "$s10" "$s14")"
     read -r s2 s6 s10 s14 <<< "$res"
     res="$(chacha20_Qround "$s3" "$s7" "$s11" "$s15")"
     read -r s3 s7 s11 s15 <<< "$res"
     res="$(chacha20_Qround "$s0" "$s5" "$s10" "$s15")"
     read -r s0 s5 s10 s15 <<< "$res"
     res="$(chacha20_Qround "$s1" "$s6" "$s11" "$s12")"
     read -r s1 s6 s11 s12 <<< "$res"
     res="$(chacha20_Qround "$s2" "$s7" "$s8" "$s13")"
     read -r s2 s7 s8 s13 <<< "$res"
     res="$(chacha20_Qround "$s3" "$s4" "$s9" "$s14")"
     read -r s3 s4 s9 s14 <<< "$res"

     tm_out "$s0 $s1 $s2 $s3 $s4 $s5 $s6 $s7 $s8 $s9 $s10 $s11 $s12 $s13 $s14 $s15"
     return 0
}

# See RFC 7539, Sections 2.3 and 2.3.1
chacha20_block() {
     local key="$1"
     local counter="$2"
     local nonce="$3"
     local s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15
     local ws0 ws1 ws2 ws3 ws4 ws5 ws6 ws7 ws8 ws9 ws10 ws11 ws12 ws13 ws14 ws15
     local working_state
     local -i i

     # create the state variable
     s0="61707865"; s1="3320646e"; s2="79622d32"; s3="6b206574"
     s4="${key:6:2}${key:4:2}${key:2:2}${key:0:2}"
     s5="${key:14:2}${key:12:2}${key:10:2}${key:8:2}"
     s6="${key:22:2}${key:20:2}${key:18:2}${key:16:2}"
     s7="${key:30:2}${key:28:2}${key:26:2}${key:24:2}"
     s8="${key:38:2}${key:36:2}${key:34:2}${key:32:2}"
     s9="${key:46:2}${key:44:2}${key:42:2}${key:40:2}"
     s10="${key:54:2}${key:52:2}${key:50:2}${key:48:2}"
     s11="${key:62:2}${key:60:2}${key:58:2}${key:56:2}"
     s12="$counter"
     s13="${nonce:6:2}${nonce:4:2}${nonce:2:2}${nonce:0:2}"
     s14="${nonce:14:2}${nonce:12:2}${nonce:10:2}${nonce:8:2}"
     s15="${nonce:22:2}${nonce:20:2}${nonce:18:2}${nonce:16:2}"

     # Initialize working_state to state
     working_state="$s0 $s1 $s2 $s3 $s4 $s5 $s6 $s7 $s8 $s9 $s10 $s11 $s12 $s13 $s14 $s15"

     # compute the 20 rounds (10 calls to inner block function, each of which
     # performs 8 quarter rounds).
     for (( i=0 ; i < 10; i++ )); do
          working_state="$(chacha20_inner_block $working_state)"
     done
     read -r ws0 ws1 ws2 ws3 ws4 ws5 ws6 ws7 ws8 ws9 ws10 ws11 ws12 ws13 ws14 ws15 <<< "$working_state"

     # Add working state to state
     s0="$(printf "%08X" $(((0x$s0+0x$ws0) & 0xffffffff)))"
     s1="$(printf "%08X" $(((0x$s1+0x$ws1) & 0xffffffff)))"
     s2="$(printf "%08X" $(((0x$s2+0x$ws2) & 0xffffffff)))"
     s3="$(printf "%08X" $(((0x$s3+0x$ws3) & 0xffffffff)))"
     s4="$(printf "%08X" $(((0x$s4+0x$ws4) & 0xffffffff)))"
     s5="$(printf "%08X" $(((0x$s5+0x$ws5) & 0xffffffff)))"
     s6="$(printf "%08X" $(((0x$s6+0x$ws6) & 0xffffffff)))"
     s7="$(printf "%08X" $(((0x$s7+0x$ws7) & 0xffffffff)))"
     s8="$(printf "%08X" $(((0x$s8+0x$ws8) & 0xffffffff)))"
     s9="$(printf "%08X" $(((0x$s9+0x$ws9) & 0xffffffff)))"
     s10="$(printf "%08X" $(((0x$s10+0x$ws10) & 0xffffffff)))"
     s11="$(printf "%08X" $(((0x$s11+0x$ws11) & 0xffffffff)))"
     s12="$(printf "%08X" $(((0x$s12+0x$ws12) & 0xffffffff)))"
     s13="$(printf "%08X" $(((0x$s13+0x$ws13) & 0xffffffff)))"
     s14="$(printf "%08X" $(((0x$s14+0x$ws14) & 0xffffffff)))"
     s15="$(printf "%08X" $(((0x$s15+0x$ws15) & 0xffffffff)))"

     # serialize the state
     s0="${s0:6:2}${s0:4:2}${s0:2:2}${s0:0:2}"
     s1="${s1:6:2}${s1:4:2}${s1:2:2}${s1:0:2}"
     s2="${s2:6:2}${s2:4:2}${s2:2:2}${s2:0:2}"
     s3="${s3:6:2}${s3:4:2}${s3:2:2}${s3:0:2}"
     s4="${s4:6:2}${s4:4:2}${s4:2:2}${s4:0:2}"
     s5="${s5:6:2}${s5:4:2}${s5:2:2}${s5:0:2}"
     s6="${s6:6:2}${s6:4:2}${s6:2:2}${s6:0:2}"
     s7="${s7:6:2}${s7:4:2}${s7:2:2}${s7:0:2}"
     s8="${s8:6:2}${s8:4:2}${s8:2:2}${s8:0:2}"
     s9="${s9:6:2}${s9:4:2}${s9:2:2}${s9:0:2}"
     s10="${s10:6:2}${s10:4:2}${s10:2:2}${s10:0:2}"
     s11="${s11:6:2}${s11:4:2}${s11:2:2}${s11:0:2}"
     s12="${s12:6:2}${s12:4:2}${s12:2:2}${s12:0:2}"
     s13="${s13:6:2}${s13:4:2}${s13:2:2}${s13:0:2}"
     s14="${s14:6:2}${s14:4:2}${s14:2:2}${s14:0:2}"
     s15="${s15:6:2}${s15:4:2}${s15:2:2}${s15:0:2}"

     tm_out "$s0$s1$s2$s3$s4$s5$s6$s7$s8$s9$s10$s11$s12$s13$s14$s15"
     return 0
}

# See RFC 7539, Section 2.4
chacha20() {
     local key="$1"
     local -i counter=1
     local nonce="$2"
     local ciphertext="$3"
     local -i i ciphertext_len num_blocks mod_check
     local -i i1 i2 i3 i4 i5 i6 i7 i8 i9 i10 i11 i12 i13 i14 i15 i16
     local keystream plaintext=""

     ciphertext_len=${#ciphertext}
     num_blocks=$ciphertext_len/128

     for (( i=0; i < num_blocks; i++)); do
          i1=128*$i; i2=$i1+8; i3=$i1+16; i4=$i1+24; i5=$i1+32; i6=$i1+40; i7=$i1+48; i8=$i1+56
          i9=$i1+64; i10=$i1+72; i11=$i1+80; i12=$i1+88; i13=$i1+96; i14=$i1+104; i15=$i1+112; i16=$i1+120
          keystream="$(chacha20_block "$key" "$(printf "%08X" $counter)" "$nonce")"
          plaintext+="$(printf "%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X" \
               "$((0x${ciphertext:i1:8} ^ 0x${keystream:0:8}))" \
               "$((0x${ciphertext:i2:8} ^ 0x${keystream:8:8}))" \
               "$((0x${ciphertext:i3:8} ^ 0x${keystream:16:8}))" \
               "$((0x${ciphertext:i4:8} ^ 0x${keystream:24:8}))" \
               "$((0x${ciphertext:i5:8} ^ 0x${keystream:32:8}))" \
               "$((0x${ciphertext:i6:8} ^ 0x${keystream:40:8}))" \
               "$((0x${ciphertext:i7:8} ^ 0x${keystream:48:8}))" \
               "$((0x${ciphertext:i8:8} ^ 0x${keystream:56:8}))" \
               "$((0x${ciphertext:i9:8} ^ 0x${keystream:64:8}))" \
               "$((0x${ciphertext:i10:8} ^ 0x${keystream:72:8}))" \
               "$((0x${ciphertext:i11:8} ^ 0x${keystream:80:8}))" \
               "$((0x${ciphertext:i12:8} ^ 0x${keystream:88:8}))" \
               "$((0x${ciphertext:i13:8} ^ 0x${keystream:96:8}))" \
               "$((0x${ciphertext:i14:8} ^ 0x${keystream:104:8}))" \
               "$((0x${ciphertext:i15:8} ^ 0x${keystream:112:8}))" \
               "$((0x${ciphertext:i16:8} ^ 0x${keystream:120:8}))")"
          counter+=1
     done

     mod_check=$ciphertext_len%128
     if [[ $mod_check -ne 0 ]]; then
          keystream="$(chacha20_block "$key" "$(printf "%08X" $counter)" "$nonce")"
          i1=128*$num_blocks
          for (( i=0; i < mod_check; i=i+2 )); do
               plaintext+="$(printf "%02X" "$((0x${ciphertext:i1:2} ^ 0x${keystream:i:2}))")"
               i1+=2
          done
     fi
     tm_out "$plaintext"
     return 0
}

# arg1: TLS cipher
# arg2: key
# arg3: nonce (must be 96 bits in length)
# arg4: ciphertext
sym-decrypt() {
     local cipher="$1"
     local key="$2" nonce="$3"
     local ciphertext="$4"
     local ossl_cipher
     local plaintext
     local -i ciphertext_len tag_len

     case "$cipher" in
          *CCM_8*)
               tag_len=16 ;;
          *CCM*|*GCM*|*CHACHA20_POLY1305*)
               tag_len=32 ;;
          *)
               return 7 ;;
     esac

     # The final $tag_len characters of the ciphertext are the authentication tag
     ciphertext_len=${#ciphertext}
     [[ $ciphertext_len -lt $tag_len ]] && return 7
     ciphertext_len=$ciphertext_len-$tag_len

     if [[ "$cipher" =~ CHACHA20_POLY1305 ]]; then
          if "$HAS_CHACHA20"; then
               plaintext="$(asciihex_to_binary_file "${ciphertext:0:ciphertext_len}" "/dev/stdout" | \
                            $OPENSSL enc -chacha20 -K "$key" -iv "01000000$nonce" 2>/dev/null | hexdump -v -e '16/1 "%02X"')"
               plaintext="$(strip_spaces "$plaintext")"
          else
               plaintext="$(chacha20 "$key" "$nonce" "${ciphertext:0:ciphertext_len}")"
          fi
     elif [[ "$cipher" == TLS_AES_128_GCM_SHA256 ]] && "$HAS_AES128_GCM"; then
          plaintext="$(asciihex_to_binary_file "${ciphertext:0:ciphertext_len}" "/dev/stdout" | \
                       $OPENSSL enc -aes-128-gcm -K "$key" -iv "$nonce" 2>/dev/null | hexdump -v -e '16/1 "%02X"')"
          plaintext="$(strip_spaces "$plaintext")"
     elif [[ "$cipher" == TLS_AES_256_GCM_SHA384 ]] && "$HAS_AES256_GCM"; then
          plaintext="$(asciihex_to_binary_file "${ciphertext:0:ciphertext_len}" "/dev/stdout" | \
                       $OPENSSL enc -aes-256-gcm -K "$key" -iv "$nonce" 2>/dev/null | hexdump -v -e '16/1 "%02X"')"
          plaintext="$(strip_spaces "$plaintext")"
     else
          if [[ "$cipher" =~ AES_128 ]]; then
               ossl_cipher="-aes-128-ecb"
          elif [[ "$cipher" =~ AES_256 ]]; then
               ossl_cipher="-aes-256-ecb"
          else
               return 7
          fi
          if [[ "$cipher" =~ CCM ]]; then
               plaintext="$(ccm-gcm-decrypt "$ossl_cipher" "$key" "02${nonce}000001" "${ciphertext:0:ciphertext_len}")"
          else # GCM
               plaintext="$(ccm-gcm-decrypt "$ossl_cipher" "$key" "${nonce}00000002" "${ciphertext:0:ciphertext_len}")"
          fi
     fi
     [[ $? -ne 0 ]] && return 7

     tm_out "$plaintext"
     return 0
}

# arg1: iv
# arg2: sequence number
get-nonce() {
     local iv="$1"
     local -i seq_num="$2"
     local -i len lsb
     local msb nonce

     len=${#iv}
     [[ $len -lt 8 ]] && return 7
     i=$len-8
     msb="${iv:0:i}"
     lsb="0x${iv:i:8}"
     nonce="${msb}$(printf "%08X" "$((lsb ^ seq_num))")"
     tm_out "$nonce"
     return 0
}

# Return:
#     0 if arg1 contains the entire server response.
#     1 if arg1 does not contain the entire server response.
#     2 if the response is malformed.
#     3 if (a) the response version is TLSv1.3;
#          (b) arg1 contains the entire ServerHello (and appears to contain the entire response);
#          (c) the entire response is supposed to be parsed; and
#          (d) the key and IV have not been provided to decrypt the response.
# arg1: ASCII-HEX encoded reply
# arg2: whether to process the full request ("all") or just the basic request plus the ephemeral key if any ("ephemeralkey").
# arg3: TLS cipher for decrypting TLSv1.3 response
# arg4: key and IV for decrypting TLSv1.3 response
check_tls_serverhellodone() {
     local tls_hello_ascii="$1"
     local process_full="$2"
     local cipher="$3"
     local key_and_iv="$4"
     local tls_handshake_ascii="" tls_alert_ascii=""
     local -i i tls_hello_ascii_len tls_handshake_ascii_len tls_alert_ascii_len
     local -i msg_len remaining tls_serverhello_ascii_len sid_len
     local -i j offset tls_extensions_len extension_len
     local tls_content_type tls_protocol tls_handshake_type tls_msg_type extension_type
     local tls_err_level
     local key iv
     local -i seq_num=0 plaintext_len
     local plaintext decrypted_response=""

     DETECTED_TLS_VERSION=""

     [[ -n "$key_and_iv" ]] && read -r key iv <<< "$key_and_iv"

     if [[ -z "$tls_hello_ascii" ]]; then
          return 0              # no server hello received
     fi

     tls_hello_ascii_len=${#tls_hello_ascii}
     for (( i=0; i<tls_hello_ascii_len; i=i+msg_len )); do
          remaining=$tls_hello_ascii_len-$i
          [[ $remaining -lt 10 ]] && return 1

          tls_content_type="${tls_hello_ascii:i:2}"
          [[ "$tls_content_type" != 14 ]] && [[ "$tls_content_type" != 15 ]] && \
               [[ "$tls_content_type" != 16 ]] && [[ "$tls_content_type" != 17 ]] && return 2
          i=$i+2
          tls_protocol="${tls_hello_ascii:i:4}"
          [[ -z "$DETECTED_TLS_VERSION" ]] && DETECTED_TLS_VERSION="$tls_protocol"
          [[ "${tls_protocol:0:2}" != 03 ]] && return 2
          i=$i+4
          msg_len=2*$(hex2dec "${tls_hello_ascii:i:4}")
          i=$i+4
          remaining=$tls_hello_ascii_len-$i
          [[ $msg_len -gt $remaining ]] && return 1

          if [[ "$tls_content_type" == 16 ]]; then
               tls_handshake_ascii+="${tls_hello_ascii:i:msg_len}"
               tls_handshake_ascii_len=${#tls_handshake_ascii}
               decrypted_response+="$tls_content_type$tls_protocol$(printf "%04X" $((msg_len/2)))${tls_hello_ascii:i:msg_len}"
               # the ServerHello MUST be the first handshake message
               [[ $tls_handshake_ascii_len -ge 2 ]] && [[ "${tls_handshake_ascii:0:2}" != 02 ]] && return 2
               if [[ $tls_handshake_ascii_len -ge 12 ]]; then
                    DETECTED_TLS_VERSION="${tls_handshake_ascii:8:4}"

                    # In TLSv1.3 (starting with draft 22), the version field specifies TLSv1.2, but
                    # there is a supported_versions extension that specifies the actual version. So,
                    # if the version field specifies TLSv1.2, then check to see if there is a
                    # supported_versions extension.
                    if [[ "$DETECTED_TLS_VERSION" == 0303 ]]; then
                         tls_serverhello_ascii_len=2*$(hex2dec "${tls_handshake_ascii:2:6}")
                         sid_len=2*$(hex2dec "${tls_handshake_ascii:76:2}")
                         if [[ $tls_serverhello_ascii_len -gt 76+$sid_len ]]; then
                              # ServerHello contains extensions, so check for supported_versions extension
                              offset=84+$sid_len
                              tls_extensions_len=2*$(hex2dec "${tls_handshake_ascii:offset:4}")
                              [[ $tls_extensions_len -ne $tls_serverhello_ascii_len-$sid_len-80 ]] && return 2
                              for (( j=0; j<tls_extensions_len; j=j+8+extension_len )); do
                                   [[ $tls_extensions_len-$j -lt 8 ]] && return 2
                                   offset=88+$sid_len+$j
                                   extension_type="${tls_handshake_ascii:offset:4}"
                                   offset=92+$sid_len+$j
                                   extension_len=2*$(hex2dec "${tls_handshake_ascii:offset:4}")
                                   [[ $extension_len -gt $tls_extensions_len-$j-8 ]] && return 2
                                   if [[ "$extension_type" == 002B ]]; then # supported_versions
                                        [[ $extension_len -ne 4 ]] && return 2
                                        offset=96+$sid_len+$j
                                        DETECTED_TLS_VERSION="${tls_handshake_ascii:offset:4}"
                                   fi
                              done
                         fi
                    fi
                    # A version of {0x7F, xx} represents an implementation of a draft version of TLS 1.3
                    [[ "${DETECTED_TLS_VERSION:0:2}" == 7F ]] && DETECTED_TLS_VERSION=0304
                    if [[ 0x$DETECTED_TLS_VERSION -ge 0x0304 ]] && [[ "$process_full" == ephemeralkey ]]; then
                         tls_serverhello_ascii_len=2*$(hex2dec "${tls_handshake_ascii:2:6}")
                         if [[ $tls_handshake_ascii_len -ge $tls_serverhello_ascii_len+8 ]]; then
                              tm_out ""
                              return 0 # The entire ServerHello message has been received (and the rest isn't needed)
                         fi
                    fi
               fi
          elif [[ "$tls_content_type" == 15 ]]; then   # TLS ALERT
               tls_alert_ascii+="${tls_hello_ascii:i:msg_len}"
               decrypted_response+="$tls_content_type$tls_protocol$(printf "%04X" $((msg_len/2)))${tls_hello_ascii:i:msg_len}"
          elif [[ "$tls_content_type" == 17 ]] && [[ -n "$key_and_iv" ]]; then # encrypted data
               nonce="$(get-nonce "$iv" "$seq_num")"
               [[ $? -ne 0 ]] && return 2
               plaintext="$(sym-decrypt "$cipher" "$key" "$nonce" "${tls_hello_ascii:i:msg_len}")"
               [[ $? -ne 0 ]] && return 2
               seq_num+=1

               # Remove zeros from end of plaintext, if any
               plaintext_len=${#plaintext}-2
               while [[ "${plaintext:plaintext_len:2}" == 00 ]]; do
                    plaintext_len=$plaintext_len-2
               done
               tls_content_type="${plaintext:plaintext_len:2}"
               decrypted_response+="${tls_content_type}0301$(printf "%04X" $((plaintext_len/2)))${plaintext:0:plaintext_len}"
               if [[ "$tls_content_type" == 16 ]]; then
                    tls_handshake_ascii+="${plaintext:0:plaintext_len}"
               elif [[ "$tls_content_type" == 15 ]]; then
                    tls_alert_ascii+="${plaintext:0:plaintext_len}"
               else
                    return 2
               fi
          fi
     done

     # If there is a fatal alert, then we are done.
     tls_alert_ascii_len=${#tls_alert_ascii}
     for (( i=0; i<tls_alert_ascii_len; i=i+4 )); do
          remaining=$tls_alert_ascii_len-$i
          [[ $remaining -lt 4 ]] && return 1
          tls_err_level=${tls_alert_ascii:i:2}    # 1: warning, 2: fatal
          [[ $tls_err_level == 02 ]] && DETECTED_TLS_VERSION="" && tm_out "" && return 0
     done

     # If there is a serverHelloDone or Finished, then we are done.
     tls_handshake_ascii_len=${#tls_handshake_ascii}
     for (( i=0; i<tls_handshake_ascii_len; i=i+msg_len )); do
          remaining=$tls_handshake_ascii_len-$i
          [[ $remaining -lt 8 ]] && return 1
          tls_msg_type="${tls_handshake_ascii:i:2}"
          i=$i+2
          msg_len=2*$(hex2dec "${tls_handshake_ascii:i:6}")
          i=$i+6
          remaining=$tls_handshake_ascii_len-$i
          [[ $msg_len -gt $remaining ]] && return 1

          # For SSLv3 - TLS1.2 look for a ServerHelloDone message.
          # For TLS 1.3 look for a Finished message.
          [[ $tls_msg_type == 0E ]] && tm_out "" && return 0
          [[ $tls_msg_type == 14 ]] && tm_out "$decrypted_response" && return 0
     done
     # If the response is TLSv1.3 and the full response is to be processed, but the
     # key and IV have not been provided to decrypt the response, then return 3 if
     # the entire ServerHello has been received.
     if [[ "$DETECTED_TLS_VERSION" == 0304 ]] && [[ "$process_full" =~ all ]] && \
        [[ -z "$key_and_iv" ]] && [[ $tls_handshake_ascii_len -gt 0 ]]; then
          return 3
     fi
     # If we haven't encountered a fatal alert or a server hello done,
     # then there must be more data to retrieve.
     return 1
}

# arg1: tls alert error/warning code
# returns: description
tls_alert() {
     local tls_alert_text=""

     case "$1" in
          00) tls_alert_text="close notify" ;;
          0A) tls_alert_text="unexpected message" ;;
          14) tls_alert_text="bad record mac" ;;
          15) tls_alert_text="decryption failed" ;;
          16) tls_alert_text="record overflow" ;;
          1E) tls_alert_text="decompression failure" ;;
          28) tls_alert_text="handshake failure" ;;
          29) tls_alert_text="no certificate RESERVED" ;;
          2A) tls_alert_text="bad certificate" ;;
          2B) tls_alert_text="unsupported certificate" ;;
          2C) tls_alert_text="certificate revoked" ;;
          2D) tls_alert_text="certificate expired" ;;
          2E) tls_alert_text="certificate unknown" ;;
          2F) tls_alert_text="illegal parameter" ;;
          30) tls_alert_text="unknown ca" ;;
          31) tls_alert_text="access denied" ;;
          32) tls_alert_text="decode error" ;;
          33) tls_alert_text="decrypt error" ;;
          3C) tls_alert_text="export restriction RESERVED" ;;
          46) tls_alert_text="protocol version" ;;
          47) tls_alert_text="insufficient security" ;;
          50) tls_alert_text="internal error" ;;
          56) tls_alert_text="inappropriate fallback" ;;
          5A) tls_alert_text="user canceled" ;;
          64) tls_alert_text="no renegotiation" ;;
          6D) tls_alert_text="missing extension" ;;
          6E) tls_alert_text="unsupported extension" ;;
          6F) tls_alert_text="certificate unobtainable" ;;
          70) tls_alert_text="unrecognized name" ;;
          71) tls_alert_text="bad certificate status response" ;;
          72) tls_alert_text="bad certificate hash value" ;;
          73) tls_alert_text="unknown psk identity" ;;
          74) tls_alert_text="certificate required" ;;
          78) tls_alert_text="no application protocol" ;;
           *) tls_alert_text="$(hex2dec "$1")";;
     esac
     echo "$tls_alert_text"
     return 0
}

# arg1: ASCII-HEX encoded reply
# arg2: (optional): "all" or "all+" - process full response (including Certificate and certificate_status handshake messages)
#                   "ephemeralkey"  - extract the server's ephemeral key (if any)
# arg3: (optional): CIPHER_SUITES string (lowercase, and in the format output by code2network())
#       If present, parse_tls_serverhello() will check that the cipher in the ServerHello appears in
#       the CIPHER_SUITES string.
parse_tls_serverhello() {
     local tls_hello_ascii="$1"
     local process_full="$2"
     local cipherlist="$3"
     local tls_handshake_ascii="" tls_alert_ascii=""
     local -i tls_hello_ascii_len tls_handshake_ascii_len tls_alert_ascii_len msg_len
     local tls_serverhello_ascii="" tls_certificate_ascii=""
     local tls_serverkeyexchange_ascii="" tls_certificate_status_ascii=""
     local tls_encryptedextensions_ascii="" tls_revised_certificate_msg=""
     local -i tls_serverhello_ascii_len=0 tls_certificate_ascii_len=0
     local -i tls_serverkeyexchange_ascii_len=0 tls_certificate_status_ascii_len=0
     local -i tls_encryptedextensions_ascii_len=0
     local added_encrypted_extensions=false
     local tls_alert_descrip tls_sid_len_hex issuerDN subjectDN CAissuerDN CAsubjectDN
     local -i tls_sid_len offset extns_offset nr_certs=0
     local tls_msg_type tls_content_type tls_protocol tls_protocol2 tls_hello_time
     local tls_err_level tls_err_descr_no tls_cipher_suite rfc_cipher_suite tls_compression_method
     local tls_extensions="" extension_type named_curve_str="" named_curve_oid
     local -i i j extension_len extn_len tls_extensions_len ocsp_response_len=0 ocsp_response_list_len ocsp_resp_offset
     local -i certificate_list_len certificate_len cipherlist_len
     local -i curve_type named_curve
     local -i dh_bits=0 msb mask
     local hostcert_issuer=""
     local len1 len2 len3 key_bitstring="" pem_certificate
     local dh_p dh_param ephemeral_param rfc7919_param
     local -i dh_p_len dh_param_len

     DETECTED_TLS_VERSION=""
     [[ $DEBUG -ge 1 ]] && echo > $TMPFILE

     [[ "$DEBUG" -ge 5 ]] && echo $tls_hello_ascii      # one line without any blanks

     # Client messages, including handshake messages, are carried by the record layer.
     # First, extract the handshake and alert messages.
     # see http://en.wikipedia.org/wiki/Transport_Layer_Security-SSL#TLS_record
     # byte 0:      content type:                 0x14=CCS,    0x15=TLS alert  x16=Handshake,  0x17 Application, 0x18=HB
     # byte 1+2:    TLS version word, major is 03, minor 00=SSL3, 01=TLS1 02=TLS1.1 03=TLS 1.2
     # byte 3+4:    fragment length
     # bytes 5...:  message fragment
     tls_hello_ascii_len=${#tls_hello_ascii}
     if [[ $DEBUG -ge 3 ]] && [[ $tls_hello_ascii_len -gt 0 ]]; then
          echo "TLS message fragments:"
     fi
     for (( i=0; i<tls_hello_ascii_len; i=i+msg_len )); do
          if [[ $tls_hello_ascii_len-$i -lt 10 ]]; then
               if [[ "$process_full" =~ all ]]; then
                    # The entire server response should have been retrieved.
                    debugme tmln_warning "Malformed message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               else
                    # This could just be a result of the server's response being
                    # split across two or more packets.
                    break
               fi
          fi
          tls_content_type="${tls_hello_ascii:i:2}"
          i=$i+2
          tls_protocol="${tls_hello_ascii:i:4}"
          i=$i+4
          msg_len=2*$(hex2dec "${tls_hello_ascii:i:4}")
          i=$i+4

          if [[ $DEBUG -ge 3 ]]; then
               echo  "     protocol (rec. layer):  0x$tls_protocol"
               echo -n "     tls_content_type:       0x$tls_content_type"
               case $tls_content_type in
                    14) tmln_out " (change cipher spec)" ;;
                    15) tmln_out " (alert)" ;;
                    16) tmln_out " (handshake)" ;;
                    17) tmln_out " (application data)" ;;
                     *) tmln_out ;;
               esac
               echo "     msg_len:                $((msg_len/2))"
               tmln_out
          fi

          if "$do_starttls" ; then
               if [[ $tls_content_type == 35 ]] || [[ $tls_content_type == 34 ]]; then
                    # STARTTLS handshake failed and server replied plaintext with a 5xx or 4xx
                    [[ $DEBUG -ge 2 ]] && printf "%s\n" "400/500: $(hex2ascii "$tls_hello_ascii" 2>/dev/null)"
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 4
               elif [[ "$tls_hello_ascii" =~ 6130303220 ]]; then
                    [[ $DEBUG -ge 2 ]] && printf "%s\n" "probably IMAP plaintext reply \"$(hex2ascii "${tls_hello_ascii:0:32}" 2>/dev/null)\""
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 3
               fi
          elif [[ $tls_content_type != 14 ]] && [[ $tls_content_type != 15 ]] && \
               [[ $tls_content_type != 16 ]] && [[ $tls_content_type != 17 ]]; then
               debugme tmln_warning "Content type other than alert, handshake, change cipher spec, or application data detected."
               [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
               return 8
          elif [[ "${tls_protocol:0:2}" != 03 ]]; then
               debugme tmln_warning "Protocol record_version.major is not 03."
               [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          DETECTED_TLS_VERSION=$tls_protocol

          if [[ $msg_len -gt $tls_hello_ascii_len-$i ]]; then
               if [[ "$process_full" =~ all ]]; then
                    debugme tmln_warning "Malformed message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 7
               else
                    # This could just be a result of the server's response being split
                    # across two or more packets. Just grab the part that is available.
                    msg_len=$tls_hello_ascii_len-$i
               fi
          fi

          if [[ $tls_content_type == 16 ]]; then
               tls_handshake_ascii="$tls_handshake_ascii${tls_hello_ascii:i:msg_len}"
          elif [[ $tls_content_type == 15 ]]; then   # TLS ALERT
               tls_alert_ascii="$tls_alert_ascii${tls_hello_ascii:i:msg_len}"
          fi
     done

     # Now check the alert messages.
     tls_alert_ascii_len=${#tls_alert_ascii}
     if [[ "$process_full" =~ all ]] && [[ $tls_alert_ascii_len%4 -ne 0 ]]; then
          debugme tmln_warning "Malformed message."
          [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
          return 1
     fi

     if [[ $tls_alert_ascii_len -gt 0 ]]; then
          debugme echo "TLS alert messages:"
          for (( i=0; i+3 < tls_alert_ascii_len; i=i+4 )); do
               tls_err_level=${tls_alert_ascii:i:2}    # 1: warning, 2: fatal
               j=$i+2
               tls_err_descr_no=${tls_alert_ascii:j:2}
               if [[ $DEBUG -ge 1 ]]; then
                    debugme tm_out  "     tls_err_descr_no:       0x${tls_err_descr_no} / = $(hex2dec ${tls_err_descr_no})"
                    tls_alert_descrip="$(tls_alert "$tls_err_descr_no")"
                    if [[ $DEBUG -ge 2 ]]; then
                         tmln_out " ($tls_alert_descrip)"
                         tm_out  "     tls_err_level:          ${tls_err_level}"
                    fi
                    case $tls_err_level in
                         01) echo -n "warning " >> $TMPFILE
                             debugme tmln_out " (warning)" ;;
                         02) echo -n "fatal " >> $TMPFILE
                             debugme tmln_out " (fatal)" ;;
                    esac
                    echo "alert $tls_alert_descrip" >> $TMPFILE
                    echo "===============================================================================" >> $TMPFILE
               fi

               if [[ "$tls_err_level" != 01 ]] && [[ "$tls_err_level" != 02 ]]; then
                    debugme tmln_warning "Unexpected AlertLevel (0x$tls_err_level)."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               elif [[ "$tls_err_level" == 02 ]]; then
                    # Fatal alert
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
          done
     fi

     # Now extract just the server hello, certificate, certificate status,
     # and server key exchange handshake messages.
     tls_handshake_ascii_len=${#tls_handshake_ascii}
     if [[ $DEBUG -ge 3 ]] && [[ $tls_handshake_ascii_len -gt 0 ]]; then
          echo "TLS handshake messages:"
     fi
     for (( i=0; i<tls_handshake_ascii_len; i=i+msg_len )); do
          if [[ $tls_handshake_ascii_len-$i -lt 8 ]]; then
               if [[ "$process_full" =~ all ]]; then
                    # The entire server response should have been retrieved.
                    debugme tmln_warning "Malformed message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               else
                    # This could just be a result of the server's response being
                    # split across two or more packets.
                    continue
               fi
          fi
          tls_msg_type="${tls_handshake_ascii:i:2}"
          i=$i+2
          msg_len=2*$(hex2dec "${tls_handshake_ascii:i:6}")
          i=$i+6
          if [[ $DEBUG -ge 3 ]]; then
               tm_out  "     handshake type:         0x${tls_msg_type}"
               case $tls_msg_type in
                    00) tmln_out " (hello_request)" ;;
                    01) tmln_out " (client_hello)" ;;
                    02) tmln_out " (server_hello)" ;;
                    03) tmln_out " (hello_verify_request)" ;;
                    04) tmln_out " (new_session_ticket)" ;;
                    05) tmln_out " (end_of_early_data)" ;;
                    06) tmln_out " (hello_retry_request)" ;;
                    08) tmln_out " (encrypted_extensions)" ;;
                    0B) tmln_out " (certificate)" ;;
                    0C) tmln_out " (server_key_exchange)" ;;
                    0D) tmln_out " (certificate_request)" ;;
                    0E) tmln_out " (server_hello_done)" ;;
                    0F) tmln_out " (certificate_verify)" ;;
                    10) tmln_out " (client_key_exchange)" ;;
                    14) tmln_out " (finished)" ;;
                    15) tmln_out " (certificate_url)" ;;
                    16) tmln_out " (certificate_status)" ;;
                    17) tmln_out " (supplemental_data)" ;;
                    18) tmln_out " (key_update)" ;;
                    19) tmln_out " (compressed_certificate)" ;;
                    FE) tmln_out " (message_hash)" ;;
                    *) tmln_out ;;
               esac
               echo "     msg_len:                $((msg_len/2))"
               tmln_out
          fi
          if [[ $msg_len -gt $tls_handshake_ascii_len-$i ]]; then
               if [[ "$process_full" =~ all ]]; then
                    debugme tmln_warning "Malformed message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               else
                    # This could just be a result of the server's response being
                    # split across two or more packets. Just grab the part that
                    # is available.
                    msg_len=$tls_handshake_ascii_len-$i
               fi
          fi

          if [[ "$tls_msg_type" == 02 ]]; then
               if [[ -n "$tls_serverhello_ascii" ]]; then
                    debugme tmln_warning "Response contained more than one ServerHello handshake message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               tls_serverhello_ascii="${tls_handshake_ascii:i:msg_len}"
               tls_serverhello_ascii_len=$msg_len
          elif [[ "$process_full" =~ all ]] && [[ "$tls_msg_type" == 08 ]]; then
               # Add excrypted extensions (now decrypted) to end of extensions in SeverHello
               tls_encryptedextensions_ascii="${tls_handshake_ascii:i:msg_len}"
               tls_encryptedextensions_ascii_len=$msg_len
               if [[ $msg_len -lt 2 ]]; then
                    debugme tmln_warning "Response contained a malformed encrypted extensions message"
                    return 1
               fi
          elif [[ "$process_full" =~ all ]] && [[ "$tls_msg_type" == 0B ]]; then
               if [[ -n "$tls_certificate_ascii" ]]; then
                    debugme tmln_warning "Response contained more than one Certificate handshake message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               tls_certificate_ascii="${tls_handshake_ascii:i:msg_len}"
               tls_certificate_ascii_len=$msg_len
          elif ( [[ "$process_full" =~ all ]] || [[ "$process_full" == ephemeralkey ]] ) && [[ "$tls_msg_type" == 0C ]]; then
               if [[ -n "$tls_serverkeyexchange_ascii" ]]; then
                    debugme tmln_warning "Response contained more than one ServerKeyExchange handshake message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               tls_serverkeyexchange_ascii="${tls_handshake_ascii:i:msg_len}"
               tls_serverkeyexchange_ascii_len=$msg_len
          elif [[ "$process_full" =~ all ]] && [[ "$tls_msg_type" == 16 ]]; then
               if [[ -n "$tls_certificate_status_ascii" ]]; then
                    debugme tmln_warning "Response contained more than one certificate_status handshake message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               tls_certificate_status_ascii="${tls_handshake_ascii:i:msg_len}"
               tls_certificate_status_ascii_len=$msg_len
          elif [[ "$tls_msg_type" == 19 ]]; then
               if [[ -n "$tls_certificate_ascii" ]]; then
                    debugme tmln_warning "Response contained more than one Certificate handshake message."
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               if [[ $DEBUG -ge 3 ]]; then
                    tm_out "          Certificate Compression Algorithm: ${tls_handshake_ascii:i:4}"
                    case ${tls_handshake_ascii:i:4} in
                         0001) tmln_out " (ZLIB)" ;;
                         0002) tmln_out " (Brotli)" ;;
                         0003) tmln_out " (Zstandard)" ;;
                         *)    tmln_out ;;
                    esac
                    offset=$((i+4))
                    tmln_out "          Uncompressed certificate length:   $(printf "%d" 0x${tls_handshake_ascii:offset:6})"
                    tmln_out
               fi
               if [[ "$process_full" =~ all ]] && "$HAS_ZLIB" && [[ "${tls_handshake_ascii:i:4}" == 0001 ]]; then
                    offset=$((i+4))
                    tls_certificate_ascii_len=2*0x${tls_handshake_ascii:offset:6}
                    offset=$((i+16))
                    len1=$((msg_len-16))
                    tls_certificate_ascii="$(asciihex_to_binary_file "${tls_handshake_ascii:offset:len1}" /dev/stdout | $OPENSSL zlib -d 2>/dev/null | hexdump -v -e '16/1 "%02X"')"
                    tls_certificate_ascii="${tls_certificate_ascii%%[!0-9A-F]*}"
                    if [[ ${#tls_certificate_ascii} -ne $tls_certificate_ascii_len ]]; then
                         debugme tmln_warning "Length of uncompressed certificates did not match specified length."
                         return 1
                    fi
               fi
          fi
     done

     if [[ $tls_serverhello_ascii_len -eq 0 ]]; then
          debugme echo "server hello empty, TCP connection closed"
          DETECTED_TLS_VERSION="closed TCP connection "
          [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
          return 1              # no server hello received
     elif [[ $tls_serverhello_ascii_len -lt 76 ]]; then
          DETECTED_TLS_VERSION="reply malformed"
          debugme echo "Malformed response"
          [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
          return 1
     elif [[ "${tls_handshake_ascii:0:2}" != 02 ]]; then
          # the ServerHello MUST be the first handshake message
          DETECTED_TLS_VERSION="reply contained no ServerHello"
          debugme tmln_warning "The first handshake protocol message is not a ServerHello."
          [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
          return 1
     fi
     if [[ $DEBUG -eq 0 ]]; then
          echo "CONNECTED(00000003)" > $TMPFILE
     else
          echo "CONNECTED(00000003)" >> $TMPFILE
     fi

     # First parse the server hello handshake message
     # byte 0+1:    03, TLS version word          see byte 1+2
     # byte 2-5:    TLS timestamp                 for OpenSSL <1.01f
     # byte 6-33:  random, 28 bytes
     # byte 34:     session id length
     # byte 35+36+sid-len:  cipher suite!
     # byte 37+sid-len:     compression method:  00: none, 01: deflate, 64: LZS
     # byte 38+39+sid-len:  extension length
     tls_protocol2="${tls_serverhello_ascii:0:4}"
     DETECTED_TLS_VERSION="$tls_protocol2"
     [[ "${DETECTED_TLS_VERSION:0:2}" == 7F ]] && DETECTED_TLS_VERSION="0304"
     if [[ "${DETECTED_TLS_VERSION:0:2}" != 03 ]]; then
          debugme tmln_warning "server_version.major in ServerHello is not 03."
          [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
          return 1
     fi

     if [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]]; then
          tls_hello_time="${tls_serverhello_ascii:4:8}"
          [[ "$TLS_DIFFTIME_SET" || "$DEBUG" ]] && TLS_TIME=$(hex2dec "$tls_hello_time")
          tls_sid_len_hex="${tls_serverhello_ascii:68:2}"
          tls_sid_len=2*$(hex2dec "$tls_sid_len_hex")
          offset=$((tls_sid_len+70))
          if [[ $tls_serverhello_ascii_len -lt 76+$tls_sid_len ]]; then
               debugme echo "Malformed response"
               [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
     else
          offset=68
     fi

     tls_cipher_suite="${tls_serverhello_ascii:offset:4}"

     if [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]]; then
          offset=$((tls_sid_len+74))
          tls_compression_method="${tls_serverhello_ascii:offset:2}"
          extns_offset=$((tls_sid_len+76))
     else
          extns_offset=72
     fi

     if [[ $tls_serverhello_ascii_len -gt $extns_offset ]] && \
        ( [[ "$process_full" =~ all ]] || [[ "$DETECTED_TLS_VERSION" == 0303 ]] || \
          ( [[ "$process_full" == ephemeralkey ]] && [[ "0x${DETECTED_TLS_VERSION:2:2}" -gt "0x03" ]] ) ); then
          if [[ $tls_serverhello_ascii_len -lt $extns_offset+4 ]]; then
               debugme echo "Malformed response"
               [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          tls_extensions_len=$(hex2dec "${tls_serverhello_ascii:extns_offset:4}")*2
          if [[ $tls_extensions_len -ne $tls_serverhello_ascii_len-$extns_offset-4 ]]; then
               debugme tmln_warning "Malformed message."
               [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          for (( i=0; i<tls_extensions_len; i=i+8+extension_len )); do
               if [[  $tls_extensions_len-$i -lt 8 ]]; then
                    debugme echo "Malformed response"
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               offset=$((extns_offset+i+4))
               extension_type="${tls_serverhello_ascii:offset:4}"
               offset=$((extns_offset+i+8))
               extension_len=2*$(hex2dec "${tls_serverhello_ascii:offset:4}")
               if [[  $extension_len -gt $tls_extensions_len-$i-8 ]]; then
                    debugme echo "Malformed response"
                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               case $extension_type in
                    0000) tls_extensions+="TLS server extension \"server name\" (id=0), len=$extension_len\n" ;;
                    0001) tls_extensions+="TLS server extension \"max fragment length\" (id=1), len=$extension_len\n" ;;
                    0002) tls_extensions+="TLS server extension \"client certificate URL\" (id=2), len=$extension_len\n" ;;
                    0003) tls_extensions+="TLS server extension \"trusted CA keys\" (id=3, len=$extension_len\n)" ;;
                    0004) tls_extensions+="TLS server extension \"truncated HMAC\" (id=4), len=$extension_len\n" ;;
                    0005) tls_extensions+="TLS server extension \"status request\" (id=5), len=$extension_len\n"
                          if [[ $extension_len -gt 0 ]] && [[ "$process_full" =~ all ]]; then
                               # In TLSv1.3 the status_request extension contains the CertificateStatus message, unlike
                               # TLSv1.2 and below where CertificateStatus appears in its own handshake message. So, if
                               # the status_request extension is not empty, extract the value and place it in
                               # $tls_certificate_status_ascii.
                               tls_certificate_status_ascii_len=$extension_len
                               offset=$((extns_offset+12+i))
                               tls_certificate_status_ascii="${tls_serverhello_ascii:offset:tls_certificate_status_ascii_len}"
                          fi
                          ;;
                    0006) tls_extensions+="TLS server extension \"user mapping\" (id=6), len=$extension_len\n" ;;
                    0007) tls_extensions+="TLS server extension \"client authz\" (id=7), len=$extension_len\n" ;;
                    0008) tls_extensions+="TLS server extension \"server authz\" (id=8), len=$extension_len\n" ;;
                    0009) tls_extensions+="TLS server extension \"cert type\" (id=9), len=$extension_len\n" ;;
                    000A) tls_extensions+="TLS server extension \"supported_groups\" (id=10), len=$extension_len\n"
                          if [[ "$process_full" =~ all ]]; then
                               if [[ $extension_len -lt 4 ]]; then
                                    debugme tmln_warning "Malformed supported groups extension."
                                    return 1
                               fi
                               echo -n "Supported groups: " >> $TMPFILE
                               offset=$((extns_offset+12+i))
                               len1=2*$(hex2dec "${tls_serverhello_ascii:offset:4}")
                               if [[ $extension_len -lt $len1+4 ]] || [[ $len1 -lt 4 ]]; then
                                    debugme tmln_warning "Malformed supported groups extension."
                                    return 1
                               fi
                               offset=$((offset+4))
                               for (( j=0; j < len1; j=j+4 )); do
                                    [[ $j -ne 0 ]] && echo -n ", " >> $TMPFILE
                                    case "${tls_serverhello_ascii:offset:4}" in
                                         "0017") echo -n "secp256r1" >> $TMPFILE ;;
                                         "0018") echo -n "secp384r1" >> $TMPFILE ;;
                                         "0019") echo -n "secp521r1" >> $TMPFILE ;;
                                         "001D") echo -n "X25519" >> $TMPFILE ;;
                                         "001E") echo -n "X448" >> $TMPFILE ;;
                                         "0100") echo -n "ffdhe2048" >> $TMPFILE ;;
                                         "0101") echo -n "ffdhe3072" >> $TMPFILE ;;
                                         "0102") echo -n "ffdhe4096" >> $TMPFILE ;;
                                         "0103") echo -n "ffdhe6144" >> $TMPFILE ;;
                                         "0104") echo -n "ffdhe8192" >> $TMPFILE ;;
                                              *) echo -n "unknown (${tls_serverhello_ascii:offset:4})" >> $TMPFILE ;;
                                    esac
                                    offset=$((offset+4))
                               done
                               echo "" >> $TMPFILE
                          fi
                          ;;
                    000B) tls_extensions+="TLS server extension \"EC point formats\" (id=11), len=$extension_len\n" ;;
                    000C) tls_extensions+="TLS server extension \"SRP\" (id=12), len=$extension_len\n" ;;
                    000D) tls_extensions+="TLS server extension \"signature algorithms\" (id=13), len=$extension_len\n" ;;
                    000E) tls_extensions+="TLS server extension \"use SRTP\" (id=14), len=$extension_len\n" ;;
                    000F) tls_extensions+="TLS server extension \"heartbeat\" (id=15), len=$extension_len\n" ;;
                    0010) tls_extensions+="TLS server extension \"application layer protocol negotiation\" (id=16), len=$extension_len\n"
                          if [[ "$process_full" =~ all ]]; then
                               if [[ $extension_len -lt 4 ]]; then
                                    debugme echo "Malformed application layer protocol negotiation extension."
                                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                    return 1
                               fi
                               echo -n "ALPN protocol:  " >> $TMPFILE
                               offset=$((extns_offset+12+i))
                               j=2*$(hex2dec "${tls_serverhello_ascii:offset:4}")
                               if [[ $extension_len -ne $j+4 ]] || [[ $j -lt 2 ]]; then
                                    debugme echo "Malformed application layer protocol negotiation extension."
                                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                    return 1
                               fi
                               offset=$((offset+4))
                               j=2*$(hex2dec "${tls_serverhello_ascii:offset:2}")
                               if [[ $extension_len -ne $j+6 ]]; then
                                    debugme echo "Malformed application layer protocol negotiation extension."
                                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                    return 1
                               fi
                               offset=$((offset+2))
                               asciihex_to_binary_file "${tls_serverhello_ascii:offset:j}" "$TMPFILE"
                               echo "" >> $TMPFILE
                               echo "===============================================================================" >> $TMPFILE
                          fi
                          ;;
                    0011) tls_extensions+="TLS server extension \"certificate status version 2\" (id=17), len=$extension_len\n" ;;
                    0012) tls_extensions+="TLS server extension \"signed certificate timestamps\" (id=18), len=$extension_len\n" ;;
                    0013) tls_extensions+="TLS server extension \"client certificate type\" (id=19), len=$extension_len\n" ;;
                    0014) tls_extensions+="TLS server extension \"server certificate type\" (id=20), len=$extension_len\n" ;;
                    0015) tls_extensions+="TLS server extension \"TLS padding\" (id=21), len=$extension_len\n" ;;
                    0016) tls_extensions+="TLS server extension \"encrypt-then-mac\" (id=22), len=$extension_len\n" ;;
                    0017) tls_extensions+="TLS server extension \"extended master secret\" (id=23), len=$extension_len\n" ;;
                    0018) tls_extensions+="TLS server extension \"token binding\" (id=24), len=$extension_len\n" ;;
                    0019) tls_extensions+="TLS server extension \"cached info\" (id=25), len=$extension_len\n" ;;
                    0023) tls_extensions+="TLS server extension \"session ticket\" (id=35), len=$extension_len\n" ;;
                    0028|0033)
                          # The key share extension was renumbered from 40 to 51 in TLSv1.3 draft 23 since a few
                          # implementations have been using 40 for the extended_random extension. Since the
                          # server's version may not yet have been determined, assume that both values represent the
                          # key share extension.
                          if [[ "$extension_type" == "00$KEY_SHARE_EXTN_NR" ]]; then
                               tls_extensions+="TLS server extension \"key share\""
                          else
                               tls_extensions+="TLS server extension \"unrecognized extension\""
                          fi
                          if [[ "$extension_type" == 0028 ]]; then
                               tls_extensions+=" (id=40), len=$extension_len\n"
                          else
                               tls_extensions+=" (id=51), len=$extension_len\n"
                          fi
                          if [[ "$process_full" =~ all ]] || [[ "$process_full" == ephemeralkey ]]; then
                               if [[ $extension_len -lt 4  ]]; then
                                    debugme tmln_warning "Malformed key share extension."
                                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                    return 1
                               fi
                               offset=$((extns_offset+12+i))
                               named_curve=$(hex2dec "${tls_serverhello_ascii:offset:4}")
                               offset=$((extns_offset+16+i))
                               msg_len=2*"$(hex2dec "${tls_serverhello_ascii:offset:4}")"
                               if [[ $msg_len -ne $extension_len-8 ]]; then
                                    debugme tmln_warning "Malformed key share extension."
                                    [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                    return 1
                               fi
                               case $named_curve in
                                    21) dh_bits=224 ; named_curve_str="P-224" ; named_curve_oid="06052b81040021" ;;
                                    23) dh_bits=256 ; named_curve_str="P-256" ; named_curve_oid="06082a8648ce3d030107" ;;
                                    24) dh_bits=384 ; named_curve_str="P-384" ; named_curve_oid="06052b81040022" ;;
                                    25) dh_bits=521 ; named_curve_str="P-521" ; named_curve_oid="06052b81040023" ;;
                                    29) dh_bits=253 ; named_curve_str="X25519" ;;
                                    30) dh_bits=448 ; named_curve_str="X448" ;;
                                    256) dh_bits=2048 ; named_curve_str="ffdhe2048" ;;
                                    257) dh_bits=3072 ; named_curve_str="ffdhe3072" ;;
                                    258) dh_bits=4096 ; named_curve_str="ffdhe4096" ;;
                                    259) dh_bits=6144 ; named_curve_str="ffdhe6144" ;;
                                    260) dh_bits=8192 ; named_curve_str="ffdhe8192" ;;
                                    *) named_curve_str="" ; named_curve_oid="" ;;
                               esac
                               offset=$((extns_offset+20+i))
                               if ! "$HAS_PKEY"; then
                                    # The key can't be extracted without the pkey utility.
                                    key_bitstring=""
                               elif [[ $named_curve -eq 29 ]]; then
                                    key_bitstring="302a300506032b656e032100${tls_serverhello_ascii:offset:msg_len}"
                               elif [[ $named_curve -eq 30 ]]; then
                                    key_bitstring="3042300506032b656f033900${tls_serverhello_ascii:offset:msg_len}"
                               elif [[ $named_curve -lt 256 ]] && [[ -n "$named_curve_oid" ]]; then
                                    len1="$(printf "%02x" $((msg_len/2+1)))"
                                    [[ "0x${len1}" -ge "0x80" ]] && len1="81${len1}"
                                    key_bitstring="03${len1}00${tls_serverhello_ascii:offset:msg_len}"
                                    len2="$(printf "%02x" $((${#named_curve_oid}/2+9)))"
                                    len3="$(printf "%02x" $((${#named_curve_oid}/2+${#key_bitstring}/2+11)))"
                                    [[ "0x${len3}" -ge "0x80" ]] && len3="81${len3}"
                                    key_bitstring="30${len3}30${len2}06072a8648ce3d0201${named_curve_oid}${key_bitstring}"
                               elif [[ "$named_curve_str" =~ "ffdhe" ]] && [[ "${TLS13_KEY_SHARES[named_curve]}" =~ "BEGIN" ]]; then
                                    dh_param="$($OPENSSL pkey -pubout -outform DER 2>>$ERRFILE <<< "${TLS13_KEY_SHARES[named_curve]}" | hexdump -v -e '16/1 "%02X"')"

                                    # First is the length of the public-key SEQUENCE, and it is always encoded in four bytes (3082xxxx)
                                    # Next is the length of the parameters SEQUENCE, and it is also always encoded in four bytes (3082xxxx)
                                    dh_param_len=8+2*"$(hex2dec "${dh_param:12:4}")"
                                    dh_param="${dh_param:8:dh_param_len}"
                                    if [[ "0x${tls_serverhello_ascii:offset:2}" -ge 0x80 ]]; then
                                         key_bitstring="00${tls_serverhello_ascii:offset:msg_len}"
                                         msg_len+=2
                                    else
                                         key_bitstring="${tls_serverhello_ascii:offset:msg_len}"
                                    fi
                                    len1="$(printf "%04x" $((msg_len/2)))"
                                    key_bitstring="0282${len1}$key_bitstring"
                                    len1="$(printf "%04x" $((${#key_bitstring}/2+1)))"
                                    key_bitstring="${dh_param}0382${len1}00$key_bitstring"
                                    len1="$(printf "%04x" $((${#key_bitstring}/2)))"
                                    key_bitstring="3082${len1}$key_bitstring"
                               fi
                               if [[ -n "$key_bitstring" ]]; then
                                    key_bitstring="$(asciihex_to_binary_file "$key_bitstring" "/dev/stdout" | $OPENSSL pkey -pubin -inform DER 2>$ERRFILE)"
                                    if [[ -z "$key_bitstring" ]] && [[ $DEBUG -ge 2 ]]; then
                                         if [[ -n "$named_curve_str" ]]; then
                                              prln_warning "Your $OPENSSL doesn't support $named_curve_str"
                                         else
                                              prln_warning "Your $OPENSSL doesn't support named curve $named_curve"
                                         fi
                                    fi
                               fi
                          fi
                          ;;
                    0029) tls_extensions+="TLS server extension \"pre-shared key\" (id=41), len=$extension_len\n" ;;
                    002A) tls_extensions+="TLS server extension \"early data\" (id=42), len=$extension_len\n" ;;
                    002B) tls_extensions+="TLS server extension \"supported versions\" (id=43), len=$extension_len\n"
                          if [[ $extension_len -ne 4 ]]; then
                               debugme tmln_warning "Malformed supported versions extension."
                               return 1
                          fi
                          offset=$((extns_offset+12+i))
                          tls_protocol2="${tls_serverhello_ascii:offset:4}"
                          DETECTED_TLS_VERSION="$tls_protocol2"
                          [[ "${DETECTED_TLS_VERSION:0:2}" == 7F ]] && DETECTED_TLS_VERSION="0304"
                          ;;
                    002C) tls_extensions+="TLS server extension \"cookie\" (id=44), len=$extension_len\n" ;;
                    002D) tls_extensions+="TLS server extension \"psk key exchange modes\" (id=45), len=$extension_len\n" ;;
                    002E) tls_extensions+="TLS server extension \"ticket early data info\" (id=46), len=$extension_len\n" ;;
                    002F) tls_extensions+="TLS server extension \"certificate authorities\" (id=47), len=$extension_len\n" ;;
                    0030) tls_extensions+="TLS server extension \"oid filters\" (id=48), len=$extension_len\n" ;;
                    0031) tls_extensions+="TLS server extension \"post handshake auth\" (id=49), len=$extension_len\n" ;;
                    3374) tls_extensions+="TLS server extension \"next protocol\" (id=13172), len=$extension_len\n"
                          if [[ "$process_full" =~ all ]]; then
                               local -i protocol_len
                               echo -n "Protocols advertised by server: " >> $TMPFILE
                               offset=$((extns_offset+12+i))
                               for (( j=0; j<extension_len; j=j+protocol_len+2 )); do
                                    if [[ $extension_len -lt $j+2 ]]; then
                                         debugme echo "Malformed next protocol extension."
                                         [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                         return 1
                                    fi
                                    protocol_len=2*$(hex2dec "${tls_serverhello_ascii:offset:2}")
                                    if [[ $extension_len -lt $j+$protocol_len+2 ]]; then
                                         debugme echo "Malformed next protocol extension."
                                         [[ $DEBUG -ge 1 ]] && tmpfile_handle ${FUNCNAME[0]}.txt
                                         return 1
                                    fi
                                    offset=$((offset+2))
                                    asciihex_to_binary_file "${tls_serverhello_ascii:offset:protocol_len}" "$TMPFILE"
                                    offset=$((offset+protocol_len))
                                    [[ $j+$protocol_len+2 -lt $extension_len ]] && echo -n ", " >> $TMPFILE
                               done
                               echo "" >> $TMPFILE
                               echo "===============================================================================" >> $TMPFILE
                          fi
                          ;;
                    FF01) tls_extensions+="TLS server extension \"renegotiation info\" (id=65281), len=$extension_len\n" ;;
                       *) tls_extensions+="TLS server extension \"unrecognized extension\" (id=$(printf "%d\n\n" "0x$extension_type")), len=$extension_len\n" ;;
               esac
               # After processing all of the extensions in the ServerHello message,
               # if it has been determined that the response is TLSv1.3 and the
               # response was decrypted, then modify $tls_serverhello_ascii by adding
               # the extensions from the EncryptedExtensions and Certificate messages
               # and then process them.
               if ! "$added_encrypted_extensions" && [[ "$DETECTED_TLS_VERSION" == "0304" ]] && \
                  [[ $((i+8+extension_len)) -eq $tls_extensions_len ]]; then
                    # Note that the encrypted extensions have been added so that
                    # the aren't added a second time.
                    added_encrypted_extensions=true
                    if [[ -n "$tls_encryptedextensions_ascii" ]]; then
                         tls_serverhello_ascii_len+=$tls_encryptedextensions_ascii_len-4
                         tls_extensions_len+=$tls_encryptedextensions_ascii_len-4
                         tls_encryptedextensions_ascii_len=$tls_encryptedextensions_ascii_len/2-2
                         offset=$((extns_offset+4))
                         tls_serverhello_ascii="${tls_serverhello_ascii:0:extns_offset}$(printf "%04X" $((0x${tls_serverhello_ascii:extns_offset:4}+$tls_encryptedextensions_ascii_len)))${tls_serverhello_ascii:offset}${tls_encryptedextensions_ascii:4}"
                    fi
                    if [[ -n "$tls_certificate_ascii" ]]; then
                         # In TLS 1.3, the Certificate message begins with a zero length certificate_request_context.
                         # In addition, certificate_list is now a list of (certificate, extension) pairs rather than
                         # just certificates. So, extract the extensions and add them to $tls_serverhello_ascii and
                         # create a new $tls_certificate_ascii that only contains a list of certificates.
                         if [[ -n "$tls_certificate_ascii" ]]; then
                              if [[ "${tls_certificate_ascii:0:2}" != "00" ]]; then
                                  debugme tmln_warning "Malformed Certificate Handshake message in ServerHello."
                                   tmpfile_handle ${FUNCNAME[0]}.txt
                                   return 1
                              fi
                              if [[ $tls_certificate_ascii_len -lt 8 ]]; then
                                   debugme tmln_warning "Malformed Certificate Handshake message in ServerHello."
                                   tmpfile_handle ${FUNCNAME[0]}.txt
                                   return 1
                              fi
                              certificate_list_len=2*$(hex2dec "${tls_certificate_ascii:2:6}")
                              if [[ $certificate_list_len -ne $tls_certificate_ascii_len-8 ]]; then
                                   debugme tmln_warning "Malformed Certificate Handshake message in ServerHello."
                                   tmpfile_handle ${FUNCNAME[0]}.txt
                                   return 1
                              fi
                              for (( j=8; j < tls_certificate_ascii_len; j=j+extn_len )); do
                                   if [[ $tls_certificate_ascii_len-$j -lt 6 ]]; then
                                        debugme tmln_warning "Malformed Certificate Handshake message in ServerHello."
                                        tmpfile_handle ${FUNCNAME[0]}.txt
                                        return 1
                                   fi
                                   certificate_len=2*$(hex2dec "${tls_certificate_ascii:j:6}")
                                   if [[ $certificate_len -gt $tls_certificate_ascii_len-$j-6 ]]; then
                                        debugme tmln_warning "Malformed Certificate Handshake message in ServerHello."
                                        tmpfile_handle ${FUNCNAME[0]}.txt
                                        return 1
                                   fi
                                   len1=$certificate_len+6
                                   tls_revised_certificate_msg+="${tls_certificate_ascii:j:len1}"
                                   j+=$len1
                                   extn_len=2*$(hex2dec "${tls_certificate_ascii:j:4}")
                                   j+=4
                                   # TODO: Should only the extensions associated with the EE certificate be added to $tls_serverhello_ascii?
                                   tls_serverhello_ascii_len+=$extn_len
                                   tls_extensions_len+=$extn_len
                                   offset=$((extns_offset+4))
                                   tls_serverhello_ascii="${tls_serverhello_ascii:0:extns_offset}$(printf "%04X" $(( 0x${tls_serverhello_ascii:extns_offset:4}+extn_len/2)) )${tls_serverhello_ascii:offset}${tls_certificate_ascii:j:extn_len}"
                              done
                              tls_certificate_ascii_len=${#tls_revised_certificate_msg}+6
                              tls_certificate_ascii="$(printf "%06X" $(( tls_certificate_ascii_len/2-3)) )$tls_revised_certificate_msg"
                         fi
                    fi
               fi
          done
     fi

     if [[ "$DETECTED_TLS_VERSION" == "0300" ]]; then
          echo "Protocol  : SSLv3" >> $TMPFILE
     else
          echo "Protocol  : TLSv1.$((0x$DETECTED_TLS_VERSION-0x0301))" >> $TMPFILE
     fi
     echo "===============================================================================" >> $TMPFILE
     if [[ $TLS_NR_CIPHERS -ne 0 ]]; then
          if [[ "${tls_cipher_suite:0:2}" == "00" ]]; then
               rfc_cipher_suite="$(show_rfc_style "x${tls_cipher_suite:2:2}")"
          else
               rfc_cipher_suite="$(show_rfc_style "x${tls_cipher_suite:0:4}")"
          fi
     elif "$HAS_CIPHERSUITES"; then
          rfc_cipher_suite="$($OPENSSL ciphers -V -ciphersuites "$TLS13_OSSL_CIPHERS" 'ALL:COMPLEMENTOFALL' | grep -i " 0x${tls_cipher_suite:0:2},0x${tls_cipher_suite:2:2} " | awk '{ print $3 }')"
     else
          rfc_cipher_suite="$($OPENSSL ciphers -V 'ALL:COMPLEMENTOFALL' | grep -i " 0x${tls_cipher_suite:0:2},0x${tls_cipher_suite:2:2} " | awk '{ print $3 }')"
     fi
     echo "Cipher    : $rfc_cipher_suite" >> $TMPFILE
     if [[ $dh_bits -ne 0 ]]; then
          if [[ "$named_curve_str" =~ "ffdhe" ]]; then
               echo "Server Temp Key: DH, $named_curve_str, $dh_bits bits" >> $TMPFILE
          elif [[ "$named_curve_str" == "X25519" ]] || [[ "$named_curve_str" == "X448" ]]; then
               echo "Server Temp Key: $named_curve_str, $dh_bits bits" >> $TMPFILE
          else
               echo "Server Temp Key: ECDH, $named_curve_str, $dh_bits bits" >> $TMPFILE
          fi
     fi
     if [[ -n "$key_bitstring" ]]; then
          echo "$key_bitstring" >> $TMPFILE
          [[ "${TLS13_KEY_SHARES[named_curve]}" =~ "BEGIN" ]] && \
               echo "${TLS13_KEY_SHARES[named_curve]}" >> $TMPFILE
     fi
     echo "===============================================================================" >> $TMPFILE
     if [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]]; then
          case $tls_compression_method in
               00) echo "Compression: NONE" >> $TMPFILE ;;
               01) echo "Compression: zlib compression" >> $TMPFILE ;;
               40) echo "Compression: LZS compression" >> $TMPFILE ;;
                *) echo "Compression: unrecognized compression method" >> $TMPFILE ;;
          esac
          echo "===============================================================================" >> $TMPFILE
     fi
     [[ -n "$tls_extensions" ]] && echo -e "$tls_extensions" >> $TMPFILE

     if [[ $DEBUG -ge 3 ]]; then
          echo "TLS server hello message:"
          if [[ $DEBUG -ge 4 ]]; then
               echo "     tls_protocol:           0x$tls_protocol2"
               [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]] && echo "     tls_sid_len:            0x$tls_sid_len_hex / = $((tls_sid_len/2))"
          fi
          if [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]]; then
               echo -n "     tls_hello_time:         0x$tls_hello_time "
               parse_date "$TLS_TIME" "+%Y-%m-%d %r" "%s"                  # in debugging mode we don't mind the cycles and don't use TLS_DIFFTIME_SET
          fi
          echo -n "     tls_cipher_suite:       0x$tls_cipher_suite"
          if [[ -n "$rfc_cipher_suite" ]]; then
               echo " ($rfc_cipher_suite)"
          else
               echo ""
          fi
          if [[ $dh_bits -ne 0 ]]; then
               if [[ "$named_curve_str" =~ "ffdhe" ]]; then
                    echo "     dh_bits:                DH, $named_curve_str, $dh_bits bits"
               elif [[ "$named_curve_str" == "X25519" ]] || [[ "$named_curve_str" == "X448" ]]; then
                    echo "     dh_bits:                $named_curve_str, $dh_bits bits"
               else
                    echo "     dh_bits:                ECDH, $named_curve_str, $dh_bits bits"
               fi
          fi
          if [[ "0x${DETECTED_TLS_VERSION:2:2}" -le "0x03" ]]; then
               echo -n "     tls_compression_method: 0x$tls_compression_method "
               case $tls_compression_method in
                    00) echo "(NONE)" ;;
                    01) echo "(zlib compression)" ;;
                    40) echo "(LZS compression)" ;;
                     *) echo "(unrecognized compression method)" ;;
               esac
          fi
          if [[ -n "$tls_extensions" ]]; then
               echo -n "     tls_extensions: "
               newline_to_spaces "$(grep -a 'TLS server extension ' $TMPFILE | \
                    sed -e 's/TLS server extension //g' -e 's/\" (id=/\/#/g' \
                        -e 's/,.*$/,/g' -e 's/),$/\"/g' \
                        -e 's/elliptic curves\/#10/supported_groups\/#10/g')"
               echo ""
               if [[ "$tls_extensions" =~ supported_groups ]]; then
                    echo "     Supported Groups:       $(grep "Supported groups:" "$TMPFILE" | sed 's/Supported groups: //')"
               fi
               if [[ "$tls_extensions" =~ application\ layer\ protocol\ negotiation ]]; then
                    echo "     ALPN protocol:          $(grep "ALPN protocol:" "$TMPFILE" | sed 's/ALPN protocol:  //')"
               fi
               if [[ "$tls_extensions" =~ next\ protocol ]]; then
                    echo "     NPN protocols:          $(grep "Protocols advertised by server:" "$TMPFILE" | sed 's/Protocols advertised by server: //')"
               fi
          fi
          tmln_out
     fi

     # If a CIPHER_SUITES string was provided, then check that $tls_cipher_suite is in the string.
     # this appeared in yassl + MySQL (https://github.com/drwetter/testssl.sh/pull/784) but adds robustness
     # to the implementation
     if [[ -n "$cipherlist" ]]; then
          tls_cipher_suite="$(tolower "$tls_cipher_suite")"
          tls_cipher_suite="${tls_cipher_suite:0:2}\\x${tls_cipher_suite:2:2}"
          cipherlist_len=${#cipherlist}
          for (( i=0; i < cipherlist_len; i=i+8 )); do
               # At the right hand side we need the quotes here!
               [[ "${cipherlist:i:6}" == "$tls_cipher_suite" ]] && break
          done
          if [[ $i -ge $cipherlist_len ]]; then
               BAD_SERVER_HELLO_CIPHER=true
               debugme echo "The ServerHello specifies a cipher suite that wasn't included in the ClientHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
     fi

     # If the ClientHello included a supported_versions extension, then check that the
     # $DETECTED_TLS_VERSION appeared in the list offered in the ClientHello.
     if [[ "${TLS_CLIENT_HELLO:0:2}" == "01" ]]; then
          # get position of cipher lists (just after session id)
          offset=78+2*$(hex2dec "${TLS_CLIENT_HELLO:76:2}")
          # get position of compression methods
          offset+=4+2*$(hex2dec "${TLS_CLIENT_HELLO:offset:4}")
          # get position of extensions
          extns_offset=$offset+6+2*$(hex2dec "${TLS_CLIENT_HELLO:offset:2}")
          len1=${#TLS_CLIENT_HELLO}
          for (( i=extns_offset; i < len1; i=i+8+extension_len )); do
               extension_type="${TLS_CLIENT_HELLO:i:4}"
               offset=4+$i
               extension_len=2*$(hex2dec "${TLS_CLIENT_HELLO:offset:4}")
               if [[ "$extension_type" == 002b ]]; then
                    offset+=6
                    tls_protocol2="$(tolower "$tls_protocol2")"
                    for (( j=0; j < extension_len-2; j=j+4 )); do
                         [[ "${TLS_CLIENT_HELLO:offset:4}" == "$tls_protocol2" ]] && break
                         offset+=4
                    done
                    if [[ $j -eq $extension_len-2 ]]; then
                         debugme echo "The ServerHello specifies a version that wasn't offered in the ClientHello."
                         tmpfile_handle ${FUNCNAME[0]}.txt
                         return 1
                    fi
                    break
               fi
          done
     fi

     # Now parse the Certificate message.
     if [[ "$process_full" =~ all ]]; then
          # not sure why we need this
          [[ -e "$HOSTCERT" ]] && rm "$HOSTCERT"
          [[ -e "$TEMPDIR/intermediatecerts.pem" ]] && > "$TEMPDIR/intermediatecerts.pem"
     fi
     if [[ $tls_certificate_ascii_len -ne 0 ]]; then
          # The first certificate is the server's certificate. If there are anything
          # subsequent certificates, they are intermediate certificates.
          if [[ $tls_certificate_ascii_len -lt 12 ]]; then
               debugme echo "Malformed Certificate Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          certificate_list_len=2*$(hex2dec "${tls_certificate_ascii:0:6}")
          if [[ $certificate_list_len -ne $tls_certificate_ascii_len-6 ]]; then
               debugme echo "Malformed Certificate Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi

          # Place server's certificate in $HOSTCERT
          certificate_len=2*$(hex2dec "${tls_certificate_ascii:6:6}")
          if [[ $certificate_len -gt $tls_certificate_ascii_len-12 ]]; then
               debugme echo "Malformed Certificate Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          asciihex_to_binary_file "${tls_certificate_ascii:12:certificate_len}" "/dev/stdout" | \
               $OPENSSL x509 -inform DER -outform PEM -out "$HOSTCERT" 2>$ERRFILE
          if [[ $? -ne 0 ]]; then
               debugme echo "Malformed certificate in Certificate Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          get_pub_key_size
          echo "===============================================================================" >> $TMPFILE
          echo "---" >> $TMPFILE
          echo "Certificate chain" >> $TMPFILE
          subjectDN="$($OPENSSL x509 -in $HOSTCERT -noout -subject 2>>$ERRFILE)"
          issuerDN="$($OPENSSL x509 -in $HOSTCERT -noout -issuer 2>>$ERRFILE)"
          echo " $nr_certs s:${subjectDN:9}" >> $TMPFILE
          echo "   i:${issuerDN:8}" >> $TMPFILE
          cat "$HOSTCERT" >> $TMPFILE

          echo "" > "$TEMPDIR/intermediatecerts.pem"
          # Place any additional certificates in $TEMPDIR/intermediatecerts.pem
          CERTIFICATE_LIST_ORDERING_PROBLEM=false
          CAissuerDN="$issuerDN"
          for (( i=12+certificate_len; i<tls_certificate_ascii_len; i=i+certificate_len )); do
               if [[ $tls_certificate_ascii_len-$i -lt 6 ]]; then
                    debugme echo "Malformed Certificate Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               certificate_len=2*$(hex2dec "${tls_certificate_ascii:i:6}")
               i+=6
               if [[ $certificate_len -gt $tls_certificate_ascii_len-$i ]]; then
                    debugme echo "Malformed certificate in Certificate Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               pem_certificate="$(asciihex_to_binary_file "${tls_certificate_ascii:i:certificate_len}" "/dev/stdout" | \
                                  $OPENSSL x509 -inform DER -outform PEM 2>$ERRFILE)"
               if [[ $? -ne 0 ]]; then
                    debugme echo "Malformed certificate in Certificate Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               nr_certs+=1
               CAsubjectDN="$($OPENSSL x509 -noout -subject 2>>$ERRFILE <<< "$pem_certificate")"
               # Check that this certificate certifies the one immediately preceding it.
               [[ "${CAsubjectDN:9}" != "${CAissuerDN:8}" ]] && CERTIFICATE_LIST_ORDERING_PROBLEM=true
               CAissuerDN="$($OPENSSL x509 -noout -issuer 2>>$ERRFILE <<< "$pem_certificate")"
               echo " $nr_certs s:${CAsubjectDN:9}" >> $TMPFILE
               echo "   i:${CAissuerDN:8}" >> $TMPFILE
               echo "$pem_certificate"  >> $TMPFILE
               echo "$pem_certificate" >> "$TEMPDIR/intermediatecerts.pem"
               if [[ -z "$hostcert_issuer" ]] && [[ "${CAsubjectDN:9}" == "${issuerDN:8}" ]]; then
                    # The issuer's certificate is needed if there is a stapled OCSP response,
                    # and it may be needed if check_revocation_ocsp() will later be called
                    # with the OCSP URI in the server's certificate.
                    hostcert_issuer="$TEMPDIR/hostcert_issuer.pem"
                    echo "$pem_certificate" > "$hostcert_issuer"
               fi
          done
          echo "---" >> $TMPFILE
          echo "Server certificate" >> $TMPFILE
          echo "subject=${subjectDN:9}" >> $TMPFILE
          echo "issuer=${issuerDN:8}" >> $TMPFILE
          echo "---" >> $TMPFILE
     fi

     # Now parse the certificate status message
     if [[ $tls_certificate_status_ascii_len -ne 0 ]] && [[ $tls_certificate_status_ascii_len -lt 8 ]]; then
          debugme echo "Malformed certificate status Handshake message in ServerHello."
          tmpfile_handle ${FUNCNAME[0]}.txt
          return 1
     elif [[ $tls_certificate_status_ascii_len -ne 0 ]] && [[ "${tls_certificate_status_ascii:0:2}" == "01" ]]; then
          # This is a certificate status message of type "ocsp"
          ocsp_response_len=2*$(hex2dec "${tls_certificate_status_ascii:2:6}")
          if [[ $ocsp_response_len -ne $tls_certificate_status_ascii_len-8 ]]; then
               debugme echo "Malformed certificate status Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          ocsp_resp_offset=8
     elif [[ $tls_certificate_status_ascii_len -ne 0 ]] && [[ "${tls_certificate_status_ascii:0:2}" == "02" ]]; then
          # This is a list of OCSP responses, but only the first one is needed
          # since the first one corresponds to the server's certificate.
          ocsp_response_list_len=2*$(hex2dec "${tls_certificate_status_ascii:2:6}")
          if [[ $ocsp_response_list_len -ne $tls_certificate_status_ascii_len-8 ]] || [[ $ocsp_response_list_len -lt 6 ]]; then
               debugme echo "Malformed certificate status Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          ocsp_response_len=2*$(hex2dec "${tls_certificate_status_ascii:8:6}")
          if [[ $ocsp_response_len -gt $ocsp_response_list_len-6 ]]; then
               debugme echo "Malformed certificate status Handshake message in ServerHello."
               tmpfile_handle ${FUNCNAME[0]}.txt
               return 1
          fi
          ocsp_resp_offset=14
     fi
     STAPLED_OCSP_RESPONSE=""
     if [[ $ocsp_response_len -ne 0 ]]; then
          STAPLED_OCSP_RESPONSE="${tls_certificate_status_ascii:ocsp_resp_offset:ocsp_response_len}"
          echo "OCSP response:" >> $TMPFILE
          echo "===============================================================================" >> $TMPFILE
          if [[ -n "$hostcert_issuer" ]]; then
               asciihex_to_binary_file "$STAPLED_OCSP_RESPONSE" "/dev/stdout" | \
                    $OPENSSL ocsp -no_nonce -CAfile $TEMPDIR/intermediatecerts.pem -issuer $hostcert_issuer -cert $HOSTCERT -respin /dev/stdin -resp_text >> $TMPFILE 2>$ERRFILE
          else
               asciihex_to_binary_file "$STAPLED_OCSP_RESPONSE" "/dev/stdout" | \
                    $OPENSSL ocsp -respin /dev/stdin -resp_text >> $TMPFILE 2>$ERRFILE
          fi
          echo "===============================================================================" >> $TMPFILE
     elif [[ "$process_full" =~ all ]]; then
          echo "OCSP response: no response sent" >> $TMPFILE
          echo "===============================================================================" >> $TMPFILE
     fi

     # Now parse the server key exchange message
     if [[ $tls_serverkeyexchange_ascii_len -ne 0 ]]; then
          if [[ $rfc_cipher_suite =~ TLS_ECDHE_ ]] || [[ $rfc_cipher_suite =~ TLS_ECDH_anon ]] || \
             [[ $rfc_cipher_suite == ECDHE* ]] || [[ $rfc_cipher_suite == AECDH* ]]; then
               if [[ $tls_serverkeyexchange_ascii_len -lt 6 ]]; then
                    debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               curve_type=$(hex2dec "${tls_serverkeyexchange_ascii:0:2}")
               if [[ $curve_type -eq 3 ]]; then
                    # named_curve - the curve is identified by a 2-byte number
                    named_curve=$(hex2dec "${tls_serverkeyexchange_ascii:2:4}")
                    # http://www.iana.org/assignments/tls-parameters/tls-parameters.xhtml#tls-parameters-8
                    case $named_curve in
                         1) dh_bits=163 ; named_curve_str="K-163" ;;
                         2) dh_bits=162 ; named_curve_str="sect163r1" ;;
                         3) dh_bits=163 ; named_curve_str="B-163" ;;
                         4) dh_bits=193 ; named_curve_str="sect193r1" ;;
                         5) dh_bits=193 ; named_curve_str="sect193r2" ;;
                         6) dh_bits=232 ; named_curve_str="K-233" ;;
                         7) dh_bits=233 ; named_curve_str="B-233" ;;
                         8) dh_bits=238 ; named_curve_str="sect239k1" ;;
                         9) dh_bits=281 ; named_curve_str="K-283" ;;
                         10) dh_bits=282 ; named_curve_str="B-283" ;;
                         11) dh_bits=407 ; named_curve_str="K-409" ;;
                         12) dh_bits=409 ; named_curve_str="B-409" ;;
                         13) dh_bits=570 ; named_curve_str="K-571" ;;
                         14) dh_bits=570 ; named_curve_str="B-571" ;;
                         15) dh_bits=161 ; named_curve_str="secp160k1" ;;
                         16) dh_bits=161 ; named_curve_str="secp160r1" ;;
                         17) dh_bits=161 ; named_curve_str="secp160r2" ;;
                         18) dh_bits=192 ; named_curve_str="secp192k1" ;;
                         19) dh_bits=192 ; named_curve_str="P-192" ;;
                         20) dh_bits=225 ; named_curve_str="secp224k1" ;;
                         21) dh_bits=224 ; named_curve_str="P-224" ;;
                         22) dh_bits=256 ; named_curve_str="secp256k1" ;;
                         23) dh_bits=256 ; named_curve_str="P-256" ;;
                         24) dh_bits=384 ; named_curve_str="P-384" ;;
                         25) dh_bits=521 ; named_curve_str="P-521" ;;
                         26) dh_bits=256 ; named_curve_str="brainpoolP256r1" ;;
                         27) dh_bits=384 ; named_curve_str="brainpoolP384r1" ;;
                         28) dh_bits=512 ; named_curve_str="brainpoolP512r1" ;;
                         29) dh_bits=253 ; named_curve_str="X25519" ;;
                         30) dh_bits=448 ; named_curve_str="X448" ;;
                    esac
               fi
               if [[ $dh_bits -ne 0 ]] && [[ $named_curve -ne 29 ]] && [[ $named_curve -ne 30 ]]; then
                    [[ $DEBUG -ge 3 ]] && echo -e "     dh_bits:                ECDH, $named_curve_str, $dh_bits bits\n"
                    echo "Server Temp Key: ECDH, $named_curve_str, $dh_bits bits" >> $TMPFILE
               elif [[ $dh_bits -ne 0 ]]; then
                    [[ $DEBUG -ge 3 ]] && echo -e "     dh_bits:                $named_curve_str, $dh_bits bits\n"
                    echo "Server Temp Key: $named_curve_str, $dh_bits bits" >> $TMPFILE
               fi
          elif [[ $rfc_cipher_suite =~ TLS_DHE_ ]] || [[ $rfc_cipher_suite =~ TLS_DH_anon ]] || \
               [[ $rfc_cipher_suite == "DHE-"* ]] || [[ $rfc_cipher_suite == "EDH-"* ]] || \
               [[ $rfc_cipher_suite == "EXP1024-DHE-"* ]]; then
               # For DH ephemeral keys the first field is p, and the length of
               # p is the same as the length of the public key.
               if [[ $tls_serverkeyexchange_ascii_len -lt 4 ]]; then
                    debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               dh_p_len=2*$(hex2dec "${tls_serverkeyexchange_ascii:0:4}")
               offset=4+$dh_p_len
               if [[ $tls_serverkeyexchange_ascii_len -lt $offset ]]; then
                    debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi

               # Subtract any leading 0 bytes
               for (( i=4; i < offset; i=i+2 )); do
                    [[ "${tls_serverkeyexchange_ascii:i:2}" != "00" ]] && break
                    dh_p_len=$dh_p_len-2
               done
               if [[ $i -ge $offset ]]; then
                    debugme echo "Malformed ServerKeyExchange Handshake message in ServerHello."
                    tmpfile_handle ${FUNCNAME[0]}.txt
                    return 1
               fi
               dh_p="${tls_serverkeyexchange_ascii:i:dh_p_len}"

               dh_bits=4*$dh_p_len
               msb=$(hex2dec "${tls_serverkeyexchange_ascii:i:2}")
               for (( mask=128; msb < mask; mask/=2 )); do
                    dh_bits=$dh_bits-1
               done

               key_bitstring="$(get_dh_ephemeralkey "$tls_serverkeyexchange_ascii")"
               [[ $? -eq 0 ]] && echo "$key_bitstring" >> $TMPFILE

               # Check to see whether the ephemeral public key uses one of the groups from
               # RFC 7919 for parameters
               case $dh_bits in
                    2048) named_curve=256; named_curve_str=" ffdhe2048," ;;
                    3072) named_curve=257; named_curve_str=" ffdhe3072," ;;
                    4096) named_curve=258; named_curve_str=" ffdhe4096," ;;
                    6144) named_curve=259; named_curve_str=" ffdhe6144," ;;
                    8192) named_curve=260; named_curve_str=" ffdhe8192," ;;
                       *) named_curve=0;   named_curve_str="" ;;
               esac
               [[ -z "$key_bitstring" ]] && named_curve=0 && named_curve_str=""
               if "$HAS_PKEY" && [[ $named_curve -ne 0 ]] && [[ "${TLS13_KEY_SHARES[named_curve]}" =~ BEGIN ]]; then
                    ephemeral_param="$($OPENSSL pkey -pubin -text -noout 2>>$ERRFILE <<< "$key_bitstring" | grep -A 1000 "prime:")"
                    rfc7919_param="$($OPENSSL pkey -text -noout 2>>$ERRFILE <<< "${TLS13_KEY_SHARES[named_curve]}" | grep -A 1000 "prime:")"
                    [[ "$ephemeral_param" != "$rfc7919_param" ]] && named_curve_str=""
               fi

               [[ $DEBUG -ge 3 ]] && [[ $dh_bits -ne 0 ]] && echo -e "     dh_bits:                DH,$named_curve_str $dh_bits bits\n"
               [[ $dh_bits -ne 0 ]] && echo "Server Temp Key: DH,$named_curve_str $dh_bits bits" >> $TMPFILE
          fi
     fi
     tmpfile_handle ${FUNCNAME[0]}.txt

     TLS_SERVER_HELLO="02$(printf "%06x" $(( tls_serverhello_ascii_len/2)) )${tls_serverhello_ascii}"
     return 0
}


#arg1 (optional): list of ciphers suites or empty
#arg2 (optional): "true" if full server response should be parsed.
# return: 6: couldn't open socket, 3(!): sslv2 handshake succeeded, 0=no SSLv2
#         1,4,6,7: see return value of parse_sslv2_serverhello()
sslv2_sockets() {
     local ret
     local client_hello cipher_suites len_client_hello
     local len_ciph_suites_byte len_ciph_suites
     local server_hello sock_reply_file2
     local -i response_len server_hello_len
     local parse_complete=false

     # this could be empty so swe use '=='
     if [[ "$2" == true ]]; then
          parse_complete=true
     fi
     if [[ -n "$1" ]]; then
          cipher_suites="$1"
     else
          cipher_suites="
          05,00,80, # 1st cipher   9 cipher specs, only classical V2 ciphers are used here, see  FIXME below
          03,00,80, # 2nd          there are v3 in v2!!! : https://tools.ietf.org/html/rfc6101#appendix-E
          01,00,80, # 3rd          Cipher specifications introduced in version 3.0 can be included in version 2.0 client hello messages using
          07,00,c0, # 4th          the syntax below. [..] # V2CipherSpec (see Version 3.0 name) = { 0x00, CipherSuite }; !!!!
          08,00,80, # 5th
          06,00,40, # 6th
          04,00,80, # 7th
          02,00,80, # 8th
          06,01,40, # 9
          07,01,c0, # 10
          FF,80,00, # 11
          FF,80,10, # 12
          00,00,00" # 13
          # FIXME: http://max.euston.net/d/tip_sslciphers.html <-- also SSLv3 ciphers
     fi

     code2network "$cipher_suites" # convert CIPHER_SUITES
     cipher_suites="$NW_STR"       # we don't have the leading \x here so string length is two byte less, see next
     len_ciph_suites_byte=${#cipher_suites}

     let "len_ciph_suites_byte += 2"
     len_ciph_suites=$(printf "%02x\n" $(( len_ciph_suites_byte / 4 )))
     len_client_hello=$(printf "%02x\n" $((0x$len_ciph_suites + 0x19)))

     client_hello="
     ,80,$len_client_hello         # length
     ,01                           # Client Hello
     ,00,02                        # SSLv2
     ,00,$len_ciph_suites          # cipher spec length
     ,00,00                        # session ID length
     ,00,10                        # challenge length
     ,$cipher_suites
     ,29,22,be,b3,5a,01,8b,04,fe,5f,80,03,a0,13,eb,c4" # Challenge
     # https://idea.popcount.org/2012-06-16-dissecting-ssl-handshake/ (client)

     fd_socket 5 || return 6
     debugme echo -n "sending client hello... "
     socksend_clienthello "$client_hello"

     sockread_serverhello 32768
     if "$parse_complete"; then
          server_hello=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          server_hello_len=2+$(hex2dec "${server_hello:1:3}")
          response_len=$(wc -c "$SOCK_REPLY_FILE" | awk '{ print $1 }')
          for (( 1; response_len < server_hello_len; 1 )); do
               sock_reply_file2=${SOCK_REPLY_FILE}.2
               mv "$SOCK_REPLY_FILE" "$sock_reply_file2"

               debugme echo -n "requesting more server hello data... "
               socksend "" $USLEEP_SND
               sockread_serverhello 32768

               [[ ! -s "$SOCK_REPLY_FILE" ]] && break
               cat "$SOCK_REPLY_FILE" >> "$sock_reply_file2"
               mv "$sock_reply_file2" "$SOCK_REPLY_FILE"
               response_len=$(wc -c "$SOCK_REPLY_FILE" | awk '{ print $1 }')
          done
     fi
     debugme echo "reading server hello... "
     if [[ "$DEBUG" -ge 4 ]]; then
          hexdump -C "$SOCK_REPLY_FILE" | head -6
          tmln_out
     fi

     parse_sslv2_serverhello "$SOCK_REPLY_FILE" "$parse_complete"
     ret=$?

     close_socket
     tmpfile_handle ${FUNCNAME[0]}.dd $SOCK_REPLY_FILE
     return $ret
}

# arg1: supported groups extension
# arg2: "all" - process full response (including Certificate and certificate_status handshake messages)
#       "ephemeralkey" - extract the server's ephemeral key (if any)
# Given the supported groups extension, create a key_share extension that includes a key share for
# each group listed in the supported groups extension.
generate_key_share_extension() {
     local supported_groups
     local -i i len supported_groups_len group
     local extn_len list_len
     local key_share key_shares=""
     local -i nr_key_shares=0

     supported_groups="${1//\\x/}"
     [[ "${supported_groups:0:4}" != "000a" ]] && return 1

     supported_groups_len=${#supported_groups}
     [[ $supported_groups_len -lt 16 ]] && return 1

     len=2*$(hex2dec "${supported_groups:4:4}")
     [[ $len+8 -ne $supported_groups_len ]] && return 1

     len=2*$(hex2dec "${supported_groups:8:4}")
     [[ $len+12 -ne $supported_groups_len ]] && return 1

     for (( i=12; i<supported_groups_len; i=i+4 )); do
          group=$(hex2dec "${supported_groups:i:4}")
          # If the Supported groups extensions lists more than one group,
          # then don't include the larger key shares in the extension.
          [[ $i -gt 12 ]] && [[ $group -gt 256 ]] && continue

          # Versions of OpenSSL prior to 1.1.0 cannot perform operations
          # with X25519 keys, so don't include the X25519 key share
          # if the server's response needs to be decrypted and an
          # older version of OpenSSL is being used.
          if [[ $i -gt 12 ]] && [[ $group -eq 29 ]] && [[ "$2" == all ]]; then
               [[ "$OSSL_NAME" =~ LibreSSL ]] && continue
               if [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR != 1.1.0* ]] && \
                  [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR != 1.1.1* ]] && \
                  [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR != 3.0.0* ]]; then
                    continue
               fi
          fi

          # Versions of OpenSSL prior to 1.1.1 cannot perform operations
          # with X448 keys, so don't include the X448 key share
          # if the server's response needs to be decrypted and an
          # older version of OpenSSL is being used.
          if [[ $i -gt 12 ]] && [[ $group -eq 30 ]] && [[ "$2" == all ]]; then
               [[ "$OSSL_NAME" =~ LibreSSL ]] && continue
               if [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR != 1.1.1* ]] && \
                  [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR != 3.0.0* ]]; then
                    continue
               fi
          fi

          # NOTE: The public keys could be extracted from the private keys
          # (TLS13_KEY_SHARES) using $OPENSSL, but only OpenSSL 1.1.0 and newer can
          # extract the public key from an X25519 private key, and only
          # OpenSSL 1.1.1 can extract the public key from an X448 private key.
          key_share="${TLS13_PUBLIC_KEY_SHARES[group]}"
          if [[ ${#key_share} -gt 4 ]]; then
               key_shares+=",$key_share"
               nr_key_shares+=1
               # Don't include more than two keys, so that the extension isn't too large.
               [[ $nr_key_shares -ge 2 ]] && break
          fi
     done
     [[ -z "$key_shares" ]] && tm_out "" && return 0

     len=${#key_shares}/3
     list_len="$(printf "%04x" "$len")"
     len+=2
     extn_len="$(printf "%04x" "$len")"
     tm_out "00,$KEY_SHARE_EXTN_NR,${extn_len:0:2},${extn_len:2:2},${list_len:0:2},${list_len:2:2}$key_shares"
     return 0
}

# ARG1: TLS version low byte (00: SSLv3,  01: TLS 1.0,  02: TLS 1.1,  03: TLS 1.2)
# ARG2: CIPHER_SUITES string (lowercase, and in the format output by code2network())
# ARG3: "all" - process full response (including Certificate and certificate_status handshake messages)
#       "all+" - same as "all", but do not offer any curves with TLSv1.3 that are not supported by
#                $OPENSSL, since response MUST be decrypted.
#       "ephemeralkey" - extract the server's ephemeral key (if any)
# ARG4: (optional) additional request extensions
# ARG5: (optional): "true" if ClientHello should advertise compression methods other than "NULL"
# ARG6: (optional): "false" if prepare_tls_clienthello() should not open a new socket
#
prepare_tls_clienthello() {
     local tls_low_byte="$1" tls_legacy_version="$1"
     local process_full="$3"
     local new_socket=true
     local tls_word_reclayer="03, 01"      # the first TLS version number is the record layer and always 0301
                                           # -- except: SSLv3 and second ClientHello after HelloRetryRequest
     local servername_hexstr len_servername len_servername_hex
     local hexdump_format_str part1 part2
     local all_extensions=""
     local -i i j len_extension len_padding_extension len_all len_session_id
     local len_sni_listlen len_sni_ext len_extension_hex len_padding_extension_hex
     local cipher_suites len_ciph_suites len_ciph_suites_byte len_ciph_suites_word
     local len_client_hello_word len_all_word
     local ecc_cipher_suite_found=false
     local extension_signature_algorithms extension_heartbeat session_id
     local extension_session_ticket extension_next_protocol extension_padding
     local extension_supported_groups="" extension_supported_point_formats=""
     local extensions_key_share="" extn_type supported_groups_c2n="" extn_psk_mode=""
     local extra_extensions extra_extensions_list="" extension_supported_versions=""
     local offer_compression=false compression_methods

     # TLSv1.3 ClientHello messages MUST specify only the NULL compression method.
     [[ "$5" == true ]] && [[ "0x$tls_low_byte" -le "0x03" ]] && offer_compression=true
     [[ "$6" == false ]] && new_socket=false

     cipher_suites="$2"                      # we don't have the leading \x here so string length is two byte less, see next
     len_ciph_suites_byte=${#cipher_suites}
     let "len_ciph_suites_byte += 2"

     # we have additional 2 chars \x in each 2 byte string and 2 byte ciphers, so we need to divide by 4:
     len_ciph_suites=$(printf "%02x\n" $(( len_ciph_suites_byte / 4 )))
     len2twobytes "$len_ciph_suites"
     len_ciph_suites_word="$LEN_STR"
     #[[ $DEBUG -ge 3 ]] && echo $len_ciph_suites_word

     if [[ "$tls_low_byte" != "00" ]]; then
          # Add extensions

          # Check to see if any ECC cipher suites are included in cipher_suites
          # (not needed for TLSv1.3)
          if [[ "0x$tls_low_byte" -le "0x03" ]]; then
               for (( i=0; i<len_ciph_suites_byte; i=i+8 )); do
                    j=$i+4
                    part1="0x${cipher_suites:$i:2}"
                    part2="0x${cipher_suites:$j:2}"
                    if [[ "$part1" == 0xc0 ]]; then
                         if [[ "$part2" -ge 0x01 ]] && [[ "$part2" -le 0x19 ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x23 ]] && [[ "$part2" -le 0x3b ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x48 ]] && [[ "$part2" -le 0x4f ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x5c ]] && [[ "$part2" -le 0x63 ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x70 ]] && [[ "$part2" -le 0x79 ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x86 ]] && [[ "$part2" -le 0x8d ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0x9a ]] && [[ "$part2" -le 0x9b ]]; then
                              ecc_cipher_suite_found=true && break
                         elif [[ "$part2" -ge 0xac ]] && [[ "$part2" -le 0xaf ]]; then
                              ecc_cipher_suite_found=true && break
                         fi
                    elif [[ "$part1" == 0xcc ]]; then
                         if [[ "$part2" == 0xa8 ]] || [[ "$part2" == 0xa9 ]] || \
                            [[ "$part2" == 0xac ]] || [[ "$part2" == 0x13 ]] || \
                            [[ "$part2" == 0x14 ]]; then
                              ecc_cipher_suite_found=true && break
                         fi
                    fi
               done
          fi

          if [[ -n "$SNI" ]]; then
               #formatted example for SNI
               #00 00    # extension server_name
               #00 1a    # length                      = the following +2 = server_name length + 5
               #00 18    # server_name list_length     = server_name length +3
               #00       # server_name type (hostname)
               #00 15    # server_name length
               #66 66 66 66 66 66 2e 66 66 66 66 66 66 66 66 66 66 2e 66 66 66  target.mydomain1.tld # server_name target
               len_servername=${#NODE}
               hexdump_format_str="$len_servername/1 \"%02x,\""
               servername_hexstr=$(printf $NODE | hexdump -v -e "${hexdump_format_str}" | sed 's/,$//')
               # convert lengths we need to fill in from dec to hex:
               len_servername_hex=$(printf "%02x\n" $len_servername)
               len_sni_listlen=$(printf "%02x\n" $((len_servername+3)))
               len_sni_ext=$(printf "%02x\n" $((len_servername+5)))
          fi

          if [[ 0x$tls_low_byte -le 0x03 ]]; then
               extension_signature_algorithms="
               00, 0d,                    # Type: signature_algorithms , see RFC 5246
               00, 20, 00,1e,             # lengths
               06,01, 06,02, 06,03, 05,01, 05,02, 05,03, 04,01, 04,02, 04,03,
               03,01, 03,02, 03,03, 02,01, 02,02, 02,03"
          else
               extension_signature_algorithms="
               00, 0d,                    # Type: signature_algorithms , see RFC 8446
               00, 22, 00, 20,            # lengths
               04,03, 05,03, 06,03, 08,04, 08,05, 08,06,
               04,01, 05,01, 06,01, 08,09, 08,0a, 08,0b,
               08,07, 08,08, 02,01, 02,03"
          fi

          extension_heartbeat="
          00, 0f, 00, 01, 01"

          extension_session_ticket="
          00, 23, 00, 00"

          extension_next_protocol="
          33, 74, 00, 00"

          extn_psk_mode="
          00, 2d, 00, 02, 01, 01"

          if "$ecc_cipher_suite_found"; then
               # Supported Groups Extension
               extension_supported_groups="
               00, 0a,                    # Type: Supported Elliptic Curves , see RFC 4492
               00, 3e, 00, 3c,            # lengths
               00, 0e, 00, 0d, 00, 19, 00, 1c, 00, 1e, 00, 0b, 00, 0c, 00, 1b,
               00, 18, 00, 09, 00, 0a, 00, 1a, 00, 16, 00, 17, 00, 1d, 00, 08,
               00, 06, 00, 07, 00, 14, 00, 15, 00, 04, 00, 05, 00, 12, 00, 13,
               00, 01, 00, 02, 00, 03, 00, 0f, 00, 10, 00, 11"
          elif [[ 0x$tls_low_byte -gt 0x03 ]]; then
               # Supported Groups Extension
               if [[ ! "$process_full" =~ all ]] || ( [[ ! "$OSSL_NAME" =~ LibreSSL ]] && \
                  ( [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.1* ]] || \
                    [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 3.0.0* ]] ) ); then
                    extension_supported_groups="
                    00,0a,                      # Type: Supported Groups, see RFC 8446
                    00,10, 00,0e,               # lengths
                    00,1d, 00,17, 00,1e, 00,18, 00,19,
                    01,00, 01,01"
                    # OpenSSL prior to 1.1.1 does not support X448, so list it as the least
                    # preferred option if the response needs to be decrypted, and do not
                    # list it at all if the response MUST be decrypted.
               elif [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == 1.1.0* ]] && [[ "$process_full" == all+ ]]; then
                    extension_supported_groups="
                    00,0a,                      # Type: Supported Groups, see RFC 8446
                    00,0e, 00,0c,               # lengths
                    00,1d, 00,17, 00,18, 00,19,
                    01,00, 01,01"
               elif [[ $OSSL_VER_MAJOR.$OSSL_VER_MINOR == "1.1.0"* ]]; then
                    extension_supported_groups="
                    00,0a,                      # Type: Supported Groups, see RFC 8446
                    00,10, 00,0e,               # lengths
                    00,1d, 00,17, 00,18, 00,19,
                    01,00, 01,01, 00,1e"
                    # OpenSSL prior to 1.1.0 does not support either X25519 or X448,
                    # so list them as the least referred options if the response
                    # needs to be decrypted, and do not list them at all if the
                    # response MUST be decrypted.
               elif [[ "$process_full" == all+ ]]; then
                    extension_supported_groups="
                    00,0a,                      # Type: Supported Groups, see RFC 8446
                    00,0c, 00,0a,               # lengths
                    00,17, 00,18, 00,19,
                    01,00, 01,01"
               else
                    extension_supported_groups="
                    00,0a,                      # Type: Supported Groups, see RFC 8446
                    00,10, 00,0e,               # lengths
                    00,17, 00,18, 00,19,
                    01,00, 01,01, 00,1d, 00,1e"
               fi

               code2network "$extension_supported_groups"
               supported_groups_c2n="$NW_STR"
          fi

          if "$ecc_cipher_suite_found" || [[ 0x$tls_low_byte -gt 0x03 ]]; then
               # Supported Point Formats Extension.
               extension_supported_point_formats="
               00, 0b,                    # Type: Supported Point Formats , see RFC 4492
               00, 02,                    # len
               01, 00"
          fi

          # Each extension should appear in the ClientHello at most once. So,
          # find out what extensions were provided as an argument and only use
          # the provided values for those extensions.
          extra_extensions="$(tolower "$4")"
          code2network "$extra_extensions"
          len_all=${#NW_STR}
          for (( i=0; i < len_all; i=i+16+4*0x$len_extension_hex )); do
               part2=$i+4
               extn_type="${NW_STR:i:2}${NW_STR:part2:2}"
               extra_extensions_list+=" $extn_type "
               j=$i+8
               part2=$j+4
               len_extension_hex="${NW_STR:j:2}${NW_STR:part2:2}"
               if [[ "$extn_type" == "000a" ]] && [[ 0x$tls_low_byte -gt 0x03 ]]; then
                    j=14+4*0x$len_extension_hex
                    supported_groups_c2n="${NW_STR:i:j}"
               fi
          done
          if [[ 0x$tls_low_byte -gt 0x03 ]]; then
               extensions_key_share="$(generate_key_share_extension "$supported_groups_c2n" "$process_full")"
               [[ $? -ne 0 ]] && return 1
          fi

          if [[ -n "$SNI" ]] && [[ ! "$extra_extensions_list" =~ " 0000 " ]]; then
               all_extensions="
                00, 00                  # extension server_name
               ,00, $len_sni_ext        # length SNI EXT
               ,00, $len_sni_listlen    # server_name list_length
               ,00                      # server_name type (hostname)
               ,00, $len_servername_hex # server_name length. We assume len(hostname) < FF - 9
               ,$servername_hexstr"     # server_name target
          fi
          if [[ 0x$tls_low_byte -ge 0x04 ]] && [[ ! "$extra_extensions_list" =~ " 002b " ]]; then
               # Add supported_versions extension listing all TLS/SSL versions
               # from the one specified in $tls_low_byte to SSLv3.
               for (( i=0x$tls_low_byte; i >=0; i=i-1 )); do
                    if [[ 0x$i -eq 4 ]]; then
                         # FIXME: The ClientHello currently advertises support for various
                         # draft versions of TLSv1.3. Eventually it should only adversize
                         # support for the final version (0304).
                         if [[ "$KEY_SHARE_EXTN_NR" == 33 ]]; then
                              extension_supported_versions+=", 03, 04, 7f, 1c, 7f, 1b, 7f, 1a, 7f, 19, 7f, 18, 7f, 17"
                         else
                              extension_supported_versions+=", 7f, 16, 7f, 15, 7f, 14, 7f, 13, 7f, 12"
                         fi
                    else
                         extension_supported_versions+=", 03, $(printf "%02x" $i)"
                    fi
               done
               [[ -n "$all_extensions" ]] && all_extensions+=","
               # FIXME: Adjust the lengths ("+15" and "+14") when the draft versions of TLSv1.3 are removed.
               if [[ "$KEY_SHARE_EXTN_NR" == "33" ]]; then
                    all_extensions+="00, 2b, 00, $(printf "%02x" $((2*0x$tls_low_byte+15))), $(printf "%02x" $((2*0x$tls_low_byte+14)))$extension_supported_versions"
               else
                    all_extensions+="00, 2b, 00, $(printf "%02x" $((2*0x$tls_low_byte+11))), $(printf "%02x" $((2*0x$tls_low_byte+10)))$extension_supported_versions"
               fi
          fi

          # There does not seem to be any reason to include this extension. However, it appears that
          # OpenSSL, Firefox, and Chrome include it in TLS 1.3 ClientHello messages, and there is at
          # least one server that will fail the connection if it is absent
          # (see https://github.com/drwetter/testssl.sh/issues/990).
          if [[ "0x$tls_low_byte" -ge 0x04 ]] && [[ ! "$extra_extensions_list" =~ " 002d " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extn_psk_mode"
          fi

          if [[ ! "$extra_extensions_list" =~ " 0023 " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_session_ticket"
          fi

          # If the ClientHello will include the ALPN extension, then don't include the NPN extension.
          if [[ ! "$extra_extensions_list" =~ " 3374 " ]] && [[ ! "$extra_extensions_list" =~ " 0010 " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_next_protocol"
          fi

          # RFC 5246 says that clients MUST NOT offer the signature algorithms
          # extension if they are offering TLS versions prior to 1.2.
          if [[ "0x$tls_low_byte" -ge 0x03 ]] && [[ ! "$extra_extensions_list" =~ " 000d " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_signature_algorithms"
          fi

          if [[ -n "$extension_supported_groups" ]] && [[ ! "$extra_extensions_list" =~ " 000a " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_supported_groups"
          fi

          if [[ -n "$extensions_key_share" ]] && [[ ! "$extra_extensions_list" =~ " 00$KEY_SHARE_EXTN_NR " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extensions_key_share"
          fi

          if [[ -n "$extension_supported_point_formats" ]] && [[ ! "$extra_extensions_list" =~ " 000b " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_supported_point_formats"
          fi

          if [[ -n "$extra_extensions" ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extra_extensions"
          fi

          # Make sure that a non-empty extension goes last (either heartbeat or padding).
          # See PR #792 and https://www.ietf.org/mail-archive/web/tls/current/msg19720.html.
          if [[ ! "$extra_extensions_list" =~ " 000f " ]]; then
               [[ -n "$all_extensions" ]] && all_extensions+=","
               all_extensions+="$extension_heartbeat"
          fi

          code2network "$all_extensions" # convert extensions
          all_extensions="$NW_STR"       # we don't have the leading \x here so string length is two byte less, see next
          len_extension=${#all_extensions}
          len_extension+=2
          len_extension=$len_extension/4
          len_extension_hex=$(printf "%02x\n" $len_extension)

          # If the length of the Client Hello would be between 256 and 511 bytes,
          # then add a padding extension (see RFC 7685)
          len_all=$((0x$len_ciph_suites + 0x2b + 0x$len_extension_hex + 0x2))
          "$offer_compression" && len_all+=2
          [[ 0x$tls_low_byte -gt 0x03 ]] && len_all+=32 # TLSv1.3 ClientHello includes a 32-byte session id
          if [[ $len_all -ge 256 ]] && [[ $len_all -le 511 ]] && [[ ! "$extra_extensions_list" =~ " 0015 " ]]; then
               if [[ $len_all -ge 508 ]]; then
                    len_padding_extension=1 # Final extension cannot be empty: see PR #792
               else
                    len_padding_extension=$((508 - len_all))
               fi
               len_padding_extension_hex=$(printf "%02x\n" $len_padding_extension)
               len2twobytes "$len_padding_extension_hex"
               all_extensions="$all_extensions\\x00\\x15\\x${LEN_STR:0:2}\\x${LEN_STR:4:2}"
               for (( i=0; i<len_padding_extension; i++ )); do
                    all_extensions="$all_extensions\\x00"
               done
               len_extension=$len_extension+$len_padding_extension+0x4
               len_extension_hex=$(printf "%02x\n" $len_extension)
          elif [[ ! "$extra_extensions_list" =~ " 0015 " ]] && ( [[ $((len_all%256)) -eq 10 ]] || [[ $((len_all%256)) -eq 14 ]] ); then
               # Some servers fail if the length of the ClientHello is 522, 778, 1034, 1290, ... bytes.
               # A few servers also fail if the length is 526, 782, 1038, 1294, ... bytes.
               # So, if the ClientHello would be one of these length, add a 5-byte padding extension.
               all_extensions="$all_extensions\\x00\\x15\\x00\\x01\\x00"
               len_extension+=5
               len_extension_hex=$(printf "%02x\n" $len_extension)
          fi
          len2twobytes "$len_extension_hex"
          all_extensions="
          ,$LEN_STR  # first the len of all extensions.
          ,$all_extensions"
     fi

     if [[ 0x$tls_low_byte -gt 0x03 ]]; then
          # TLSv1.3 calls for sending a random 32-byte session id in middlebox compatibility mode.
          session_id="20,44,b8,92,56,af,74,52,9e,d8,cf,52,14,c8,af,d8,34,0b,e7,7f,eb,86,01,84,50,5d,e4,a1,6a,09,3b,bf,6e"
          len_session_id=32
     else
          session_id="00"
          len_session_id=0
     fi

     # RFC 3546 doesn't specify SSLv3 to have SNI, openssl just ignores the switch if supplied
     if [[ "$tls_low_byte" == "00" ]]; then
          len_all=$((0x$len_ciph_suites + len_session_id + 0x27))
     else
          len_all=$((0x$len_ciph_suites + len_session_id + 0x27 + 0x$len_extension_hex + 0x2))
     fi
     "$offer_compression" && len_all+=2
     len2twobytes $(printf "%02x\n" $len_all)
     len_client_hello_word="$LEN_STR"
     #[[ $DEBUG -ge 3 ]] && echo $len_client_hello_word

     if [[ "$tls_low_byte" == 00 ]]; then
          len_all=$((0x$len_ciph_suites + len_session_id + 0x2b))
     else
          len_all=$((0x$len_ciph_suites + len_session_id + 0x2b + 0x$len_extension_hex + 0x2))
     fi
     "$offer_compression" && len_all+=2
     len2twobytes $(printf "%02x\n" $len_all)
     len_all_word="$LEN_STR"
     #[[ $DEBUG -ge 3 ]] && echo $len_all_word

     # if we have SSLv3, the first occurrence of TLS protocol -- record layer -- is SSLv3, otherwise TLS 1.0,
     # except in the case of a second ClientHello in TLS 1.3, in which case it is TLS 1.2.
     [[ $tls_low_byte == "00" ]] && tls_word_reclayer="03, 00"

     [[ 0x$tls_legacy_version -ge 0x04 ]] && tls_legacy_version="03"

     if "$offer_compression"; then
          # See http://www.iana.org/assignments/comp-meth-ids/comp-meth-ids.xhtml#comp-meth-ids-2
          compression_methods="03,01,40,00" # Offer NULL, DEFLATE, and LZS compression
     else
          compression_methods="01,00" # Only offer NULL compression (0x00)
     fi

     TLS_CLIENT_HELLO="
     # TLS header ( 5 bytes)
     ,16, $tls_word_reclayer  # TLS Version: in wireshark this is always 01 for TLS 1.0-1.2
     ,$len_all_word           # Length  <---
     # Handshake header:
     ,01                      # Type (x01 for ClientHello)
     ,00, $len_client_hello_word   # Length ClientHello
     ,03, $tls_legacy_version # TLS version ClientHello
     ,54, 51, 1e, 7a          # Unix time since  see www.moserware.com/2009/06/first-few-milliseconds-of-https.html
     ,de, ad, be, ef          # Random 28 bytes
     ,31, 33, 07, 00, 00, 00, 00, 00
     ,cf, bd, 39, 04, cc, 16, 0b, 85
     ,03, 90, 9f, 77, 04, 33, d4, de
     ,$session_id
     ,$len_ciph_suites_word   # Cipher suites length
     ,$cipher_suites
     ,$compression_methods"

     if "$new_socket"; then
          fd_socket 5 || return 6
     fi

     debugme echo -n "sending client hello... "
     socksend_clienthello "$TLS_CLIENT_HELLO$all_extensions" $USLEEP_SND

     if [[ "$tls_low_byte" -gt 0x03 ]]; then
          TLS_CLIENT_HELLO="$(tolower "$NW_STR")"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x0\\/\\x00\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x1\\/\\x01\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x2\\/\\x02\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x3\\/\\x03\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x4\\/\\x04\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x5\\/\\x05\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x6\\/\\x06\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x7\\/\\x07\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x8\\/\\x08\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x9\\/\\x09\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xa\\/\\x0a\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xb\\/\\x0b\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xc\\/\\x0c\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xd\\/\\x0d\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xe\\/\\x0e\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\xf\\/\\x0f\\}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO//\\x/}"
          TLS_CLIENT_HELLO="${TLS_CLIENT_HELLO:10}"
     fi

     return 0
}

# arg1: The original ClientHello
# arg2: The server's response
# Return 0 if the response is not a HelloRetryRequest.
# Return 1 if the response is a malformed HelloRetryRequest or if a new ClientHello cannot be sent.
# Return 2 if the response is a HelloRetryRequest, and sending a new ClientHello succeeded.
# Return 6 if the response is a HelloRetryRequest, and sending a new ClientHello failed.
resend_if_hello_retry_request() {
     local original_clienthello="$1"
     local tls_hello_ascii="$2"
     local msg_type tls_low_byte server_version cipher_suite rfc_cipher_suite
     local key_share="" new_key_share="" cookie="" second_clienthello data=""
     local -i i j msg_len tls_hello_ascii_len sid_len
     local -i extns_offset hrr_extns_len extra_extensions_len len_extn
     local extra_extensions extn_type part2 new_extra_extns=""
     local sha256_hrr="CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C"

     tls_hello_ascii_len=${#tls_hello_ascii}
     # A HelloRetryRequest is at least 13 bytes long
     [[ $tls_hello_ascii_len -lt 26 ]] && return 0
     # A HelloRetryRequest is a handshake message (16) with a major record version of 03.
     [[ "${tls_hello_ascii:0:4}" != 1603 ]] && return 0
     msg_type="${tls_hello_ascii:10:2}"
     if [[ "$msg_type" == 02 ]]; then
          # A HRR is a ServerHello with a Random value equal to the
          # SHA-256 hash of "HelloRetryRequest"
          [[ $tls_hello_ascii_len -lt 76 ]] && return 0
          [[ "${tls_hello_ascii:22:64}" != $sha256_hrr ]] && return 0
     elif [[ "$msg_type" != 06 ]]; then
          # The handshake type for hello_retry_request in draft versions was 06.
          return 0
     fi

     # This appears to be a HelloRetryRequest message.
     debugme echo "reading hello retry request... "
     if [[ "$DEBUG" -ge 4 ]]; then
          hexdump -C $SOCK_REPLY_FILE | head -6
          echo
          [[ "$DEBUG" -ge 5 ]] && echo "$tls_hello_ascii"      # one line without any blanks
     fi

     # Check the length of the handshake message
     msg_len=2*$(hex2dec "${tls_hello_ascii:6:4}")
     if [[ $msg_len -gt $tls_hello_ascii_len-10 ]]; then
          debugme echo "malformed HelloRetryRequest"
          return 1
     fi
     # The HelloRetryRequest message may be followed by something
     # else (e.g., a change cipher spec message). Ignore anything
     # that follows.
     tls_hello_ascii_len=$msg_len+10

     # Check the length of the HelloRetryRequest message.
     msg_len=2*$(hex2dec "${tls_hello_ascii:12:6}")
     if [[ $msg_len -ne $tls_hello_ascii_len-18 ]]; then
          debugme echo "malformed HelloRetryRequest"
          return 1
     fi

     if [[ "$msg_type" == 06 ]]; then
          server_version="${tls_hello_ascii:18:4}"
          if [[ 0x$server_version -ge 0x7f13 ]]; then
               # Starting with TLSv1.3 draft 19, a HelloRetryRequest is at least 15 bytes long
               [[ $tls_hello_ascii_len -lt 30 ]] && return 0
               cipher_suite="${tls_hello_ascii:22:2},${tls_hello_ascii:24:2}"
               extns_offset=26
          else
              extns_offset=22
          fi
     else
          sid_len=2*$(hex2dec "${tls_hello_ascii:86:2}")
          i=88+$sid_len
          j=90+$sid_len
          cipher_suite="${tls_hello_ascii:i:2},${tls_hello_ascii:j:2}"
          extns_offset=94+$sid_len
     fi

     # Check the length of the extensions.
     hrr_extns_len=2*$(hex2dec "${tls_hello_ascii:extns_offset:4}")
     if [[ $hrr_extns_len -ne $tls_hello_ascii_len-$extns_offset-4 ]]; then
          debugme echo "malformed HelloRetryRequest"
          return 1
     fi

     # Parse HelloRetryRequest extensions
     for (( i=extns_offset+4; i < tls_hello_ascii_len; i=i+8+len_extn )); do
          extn_type="${tls_hello_ascii:i:4}"
          j=$i+4
          len_extn=2*$(hex2dec "${tls_hello_ascii:j:4}")
          j+=4
          if [[ $len_extn -gt $tls_hello_ascii_len-$j ]]; then
               debugme echo "malformed HelloRetryRequest"
               return 1
          fi
          if [[ "$extn_type" == 002C ]]; then
               # If the HRR includes a cookie extension, then it needs to be
               # included in the next ClientHello.
               j=8+$len_extn
               cookie="${tls_hello_ascii:i:j}"
          elif [[ "$extn_type" == 00$KEY_SHARE_EXTN_NR ]]; then
               # If the HRR includes a key_share extension, then it specifies the
               # group to be used in the next ClientHello. So, create a key_share
               # extension that specifies this group.
               if [[ $len_extn -ne 4 ]]; then
                    debugme echo "malformed key share extension in HelloRetryRequest"
                    return 1
               fi
               key_share="${tls_hello_ascii:j:4}"
               new_key_share="$(generate_key_share_extension "000a00040002$key_share" "ephemeralkey")"
               [[ $? -ne 0 ]] && return 1
               [[ -z "$new_key_share" ]] && return 1
               new_key_share="${new_key_share//,/}"
          elif [[ "$extn_type" == 002B ]]; then
               if [[ $len_extn -ne 4 ]]; then
                    debugme echo "malformed supported versions extension in HelloRetryRequest"
                    return 1
               fi
               server_version="${tls_hello_ascii:j:4}"
          fi
     done

     if [[ $DEBUG -ge 3 ]]; then
          echo "TLS message fragments:"
          echo "     tls_protocol (reclyr):  0x${tls_hello_ascii:2:4}"
          echo "     tls_content_type:       0x16 (handshake)"
          echo "     msg_len:                $(hex2dec "${tls_hello_ascii:6:4}")"
          echo
          echo "TLS handshake message:"
          echo -n "     handshake type:         0x$msg_type "
          case "$msg_type" in
               02) echo "(hello_retry_request formatted as server_hello)" ;;
               06) echo "(hello_retry_request)" ;;
          esac
          echo "     msg_len:                $(hex2dec "${tls_hello_ascii:12:6}")"
          echo
          echo "TLS hello retry request message:"
          echo "     server version:         $server_version"
          if [[ "$server_version" == 0304 ]] || [[ 0x$server_version -ge 0x7f13 ]]; then
               echo -n "     cipher suite:           $cipher_suite"
               if [[ $TLS_NR_CIPHERS -ne 0 ]]; then
                    if [[ "${cipher_suite:0:2}" == "00" ]]; then
                         rfc_cipher_suite="$(show_rfc_style "x${cipher_suite:3:2}")"
                    else
                         rfc_cipher_suite="$(show_rfc_style "x${cipher_suite:0:2}${cipher_suite:3:2}")"
                    fi
               elif "$HAS_CIPHERSUITES"; then
                    rfc_cipher_suite="$($OPENSSL ciphers -V -ciphersuites "$TLS13_OSSL_CIPHERS" 'ALL:COMPLEMENTOFALL' | grep -i " 0x${cipher_suite:0:2},0x${cipher_suite:3:2} " | awk '{ print $3 }')"
               else
                    rfc_cipher_suite="$($OPENSSL ciphers -V 'ALL:COMPLEMENTOFALL' | grep -i " 0x${cipher_suite:0:2},0x${cipher_suite:3:2} " | awk '{ print $3 }')"
               fi
               if [[ -n "$rfc_cipher_suite" ]]; then
                    echo " ($rfc_cipher_suite)"
               else
                    echo ""
               fi
          fi
          [[ -n "$key_share" ]] && echo "     key share:              0x$key_share"
          [[ -n "$cookie" ]] && echo "     cookie:                 $cookie"
     fi

     # Starting with TLSv1.3 draft 24, the second ClientHello should specify a record layer version of 0x0303
     if [[ "$server_version" == 0304 ]] || [[ 0x$server_version -ge 0x7f18 ]]; then
          original_clienthello="160303${original_clienthello:6}"
     fi

     if [[ "$server_version" == 0304 ]] || [[ 0x$server_version -ge 0x7f16 ]]; then
         # Send a dummy change cipher spec for middlebox compatibility.
         debugme echo -en "\nsending dummy change cipher spec... "
         socksend ", x14, x03, x03 ,x00, x01, x01" 0
     fi
     debugme echo -en "\nsending second client hello... "
     second_clienthello="$(modify_clienthello "$original_clienthello" "$new_key_share" "$cookie")"
     msg_len=${#second_clienthello}
     for (( i=0; i < msg_len; i=i+2 )); do
          data+=", ${second_clienthello:i:2}"
     done
     debugme echo -n "sending client hello... "
     socksend_clienthello "$data" $USLEEP_SND
     sockread_serverhello 32768
     return 2
}

# arg1: TLS version low byte
#       (00: SSLv3,  01: TLS 1.0,  02: TLS 1.1,  03: TLS 1.2)
# arg2: (optional) list of cipher suites
# arg3: (optional): "all" - process full response (including Certificate and certificate_status handshake messages)
#                   "all+" - same as "all", but do not offer any curves with TLSv1.3 that are not supported by
#                            $OPENSSL, since response MUST be decrypted.
#                   "ephemeralkey" - extract the server's ephemeral key (if any)
# arg4: (optional) additional request extensions
# arg5: (optional) "true" if ClientHello should advertise compression methods other than "NULL"
# arg6: (optional) "false" if the connection should not be closed before the function returns.
# return: 0: successful connect   | 1: protocol or cipher not available | 2: as (0) but downgraded
#         6: couldn't open socket | 7: couldn't open temp file
tls_sockets() {
     local -i ret=0
     local -i save=0
     local lines
     local tls_low_byte
     local cipher_list_2send
     local sock_reply_file2 sock_reply_file3
     local tls_hello_ascii next_packet
     local clienthello1 original_clienthello hrr=""
     local process_full="$3" offer_compression=false skip=false
     local close_connection=true
     local -i hello_done=0
     local cipher="" key_and_iv="" decrypted_response

     [[ "$5" == true ]] && offer_compression=true
     [[ "$6" == false ]] && close_connection=false
     tls_low_byte="$1"
     if [[ -n "$2" ]]; then             # use supplied string in arg2 if there is one
          cipher_list_2send="$2"
     else                               # otherwise use std ciphers then
          if [[ "$tls_low_byte" == 03 ]]; then
               cipher_list_2send="$TLS12_CIPHER"
          else
               cipher_list_2send="$TLS_CIPHER"
          fi
     fi
     code2network "$(tolower "$cipher_list_2send")"   # convert CIPHER_SUITES to a "standardized" format
     cipher_list_2send="$NW_STR"

     debugme echo -en "\nsending client hello... "
     prepare_tls_clienthello "$tls_low_byte" "$cipher_list_2send" "$process_full" "$4" "$offer_compression"
     ret=$?                             # 6 means opening socket didn't succeed, e.g. timeout

     # if sending didn't succeed we don't bother
     if [[ $ret -eq 0 ]]; then
          clienthello1="$TLS_CLIENT_HELLO"
          sockread_serverhello 32768
          "$TLS_DIFFTIME_SET" && TLS_NOW=$(LC_ALL=C date "+%s")

          tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          tls_hello_ascii="${tls_hello_ascii%%[!0-9A-F]*}"

          # Check if the response is a HelloRetryRequest.
          original_clienthello="160301$(printf "%04x" "${#clienthello1}")$clienthello1"
          resend_if_hello_retry_request "$original_clienthello" "$tls_hello_ascii"
          ret=$?
          if [[ $ret -eq 2 ]]; then
               hrr="${tls_hello_ascii:10}"
               tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
               tls_hello_ascii="${tls_hello_ascii%%[!0-9A-F]*}"
          elif [[ $ret -eq 1 ]] || [[ $ret -eq 6 ]]; then
               close_socket
               TMPFILE=$SOCK_REPLY_FILE
               tmpfile_handle ${FUNCNAME[0]}.dd
               return $ret
          fi

          # The server's response may span more than one packet. If only the
          # first part of the response needs to be processed, this isn't an
          # issue. However, if the entire response needs to be processed or
          # if the ephemeral key is needed (which comes last for TLS 1.2 and
          # below), then we need to check if response appears to be complete,
          # and if it isn't then try to get another packet from the server.
          if [[ "$process_full" =~ all ]] || [[ "$process_full" == ephemeralkey ]]; then
               hello_done=1; skip=true
          fi
          for (( 1 ; hello_done==1; 1 )); do
               if ! "$skip"; then
                    if [[ $DEBUG -ge 1 ]]; then
                         sock_reply_file2=$(mktemp $TEMPDIR/ddreply.XXXXXX) || return 7
                         mv "$SOCK_REPLY_FILE" "$sock_reply_file2"
                    fi

                    debugme echo -n "requesting more server hello data... "
                    socksend "" $USLEEP_SND
                    sockread_serverhello 32768

                    next_packet=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
                    next_packet="${next_packet%%[!0-9A-F]*}"

                    if [[ ${#next_packet} -eq 0 ]]; then
                         # This shouldn't be necessary. However, it protects against
                         # getting into an infinite loop if the server has nothing
                         # left to send and check_tls_serverhellodone doesn't
                         # correctly catch it.
                         [[ $DEBUG -ge 1 ]] && mv "$sock_reply_file2" "$SOCK_REPLY_FILE"
                         hello_done=0
                    else
                         tls_hello_ascii+="$next_packet"
                         if [[ $DEBUG -ge 1 ]]; then
                              sock_reply_file3=$(mktemp $TEMPDIR/ddreply.XXXXXX) || return 7
                              mv "$SOCK_REPLY_FILE" "$sock_reply_file3"
                              mv "$sock_reply_file2" "$SOCK_REPLY_FILE"
                              cat "$sock_reply_file3" >> "$SOCK_REPLY_FILE"
                              rm "$sock_reply_file3"
                         fi
                    fi
               fi
               skip=false
               if [[ $hello_done -eq 1 ]]; then
                    decrypted_response="$(check_tls_serverhellodone "$tls_hello_ascii" "$process_full" "$cipher" "$key_and_iv")"
                    hello_done=$?
                    [[ "$hello_done" -eq 0 ]] && [[ -n "$decrypted_response" ]] && tls_hello_ascii="$(toupper "$decrypted_response")"
                    if [[ "$hello_done" -eq 3 ]]; then
                         hello_done=1; skip=true
                         debugme echo "reading server hello..."
                         parse_tls_serverhello "$tls_hello_ascii" "ephemeralkey"
                         ret=$?
                         if [[ "$ret" -eq 0 ]] || [[ "$ret" -eq 2 ]]; then
                              cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                              if [[ -n "$hrr" ]]; then
                                   key_and_iv="$(derive-handshake-traffic-keys "$cipher" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" "$clienthello1" "$hrr" "$TLS_CLIENT_HELLO" "$TLS_SERVER_HELLO")"
                              else
                                   key_and_iv="$(derive-handshake-traffic-keys "$cipher" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" "" "" "$TLS_CLIENT_HELLO" "$TLS_SERVER_HELLO")"
                              fi
                              [[ $? -ne 0 ]] && hello_done=2
                         else
                              hello_done=2
                         fi
                    fi
               fi
          done

          debugme echo "reading server hello..."
          if [[ "$DEBUG" -ge 4 ]]; then
               hexdump -C $SOCK_REPLY_FILE | head -6
               echo
          fi

          parse_tls_serverhello "$tls_hello_ascii" "$process_full" "$cipher_list_2send"
          save=$?
          if "$close_connection" && [[ $save == 0 ]]; then
               send_close_notify "$DETECTED_TLS_VERSION"
          fi

          if [[ $DEBUG -ge 2 ]]; then
               # see https://secure.wand.net.nz/trac/libprotoident/wiki/SSL
               lines=$(count_lines "$(hexdump -C "$SOCK_REPLY_FILE" 2>$ERRFILE)")
               tm_out "  ($lines lines returned)  "
          fi

          # determine the return value for higher level, so that they can tell what the result is
          if [[ $save -eq 1 ]] || [[ $lines -eq 1 ]]; then
               ret=1          # NOT available
          elif [[ $save -eq 3 ]]; then
               # only for IMAP currently 'a002 NO Starttls'
               ret=3
          elif [[ $save -eq 8 ]]; then
               # odd return, we just pass this from parse_tls_serverhello() back
               ret=8
          elif [[ $save -eq 4 ]]; then
               # STARTTLS problem passing back
               ret=4
          else
               if [[ 03$tls_low_byte -eq $DETECTED_TLS_VERSION ]]; then
                    ret=0     # protocol available, TLS version returned equal to the one send
               else
                    debugme echo -n "protocol send: 0x03$tls_low_byte, returned: 0x$DETECTED_TLS_VERSION"
                    ret=2     # protocol NOT available, server downgraded to $DETECTED_TLS_VERSION
               fi
          fi
          debugme echo
     else
          debugme echo "stuck on sending: $ret"
     fi

     "$close_connection" && close_socket
     tmpfile_handle ${FUNCNAME[0]}.dd $SOCK_REPLY_FILE
     return $ret
}


####### Vulnerabilities follow #######
# General overview which browser "supports" which vulnerability:
# http://en.wikipedia.org/wiki/Transport_Layer_Security-SSL#Web_browsers

# mainly adapted from https://gist.github.com/takeshixx/10107280
#
run_heartbleed(){
     local tls_hexcode
     local heartbleed_payload
     local -i n lines_returned
     local append=""
     local tls_hello_ascii=""
     local jsonID="heartbleed"
     local cve="CVE-2014-0160"
     local cwe="CWE-119"
     local hint=""

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for heartbleed vulnerability " && outln
     pr_bold " Heartbleed"; out " ($cve)                "

     if ( [[ "$STARTTLS_PROTOCOL" =~ ldap ]] || [[ "$STARTTLS_PROTOCOL" =~ irc ]] ); then
          prln_local_problem "STARTTLS/$STARTTLS_PROTOCOL and --ssl-native collide here"
          return 1
     fi

     [[ -z "$TLS_EXTENSIONS" ]] && determine_tls_extensions
     if [[ ! "${TLS_EXTENSIONS}" =~ heartbeat ]]; then
          pr_svrty_best "not vulnerable (OK)"
          outln ", no heartbeat extension"
          fileout "$jsonID" "OK" "not vulnerable, no heartbeat extension" "$cve" "$cwe"
          return 0
     fi

     if [[ 0 -eq $(has_server_protocol tls1) ]]; then
          tls_hexcode="x03, x01"
     elif [[ 0 -eq $(has_server_protocol tls1_1) ]]; then
          tls_hexcode="x03, x02"
     elif [[ 0 -eq $(has_server_protocol tls1_2) ]]; then
          tls_hexcode="x03, x03"
     elif [[ 0 -eq $(has_server_protocol ssl3) ]]; then
          tls_hexcode="x03, x00"
     else # no protocol for some reason defined, determine TLS versions offered with a new handshake
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY") >$TMPFILE 2>$ERRFILE </dev/null
          case "$(get_protocol $TMPFILE)" in
               *1.2)  tls_hexcode="x03, x03" ; add_tls_offered tls1_2 yes ;;
               *1.1)  tls_hexcode="x03, x02" ; add_tls_offered tls1_1 yes ;;
               TLSv1) tls_hexcode="x03, x01" ; add_tls_offered tls1 yes ;;
               SSLv3) tls_hexcode="x03, x00" ; add_tls_offered ssl3 yes ;;
          esac
     fi
     debugme echo "using protocol $tls_hexcode"

     heartbleed_payload=", x18, $tls_hexcode, x00, x03, x01, x40, x00"
     tls_sockets "${tls_hexcode:6:2}" "" "ephemeralkey" "" "" "false"

     [[ $DEBUG -ge 4 ]] && tmln_out "\nsending payload with TLS version $tls_hexcode:"
     socksend "$heartbleed_payload" 1
     sockread_serverhello 16384 $HEARTBLEED_MAX_WAITSOCK
     if [[ $? -eq 3 ]]; then
          append=", timed out"
          pr_svrty_best "not vulnerable (OK)"; out "$append"
          fileout "$jsonID" "OK" "not vulnerable $append" "$cve" "$cwe"
     else

          # server reply should be (>=SSLv3): 18030x in case of a heartBEAT reply -- which we take as a positive result
          tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          debugme echo "tls_content_type: ${tls_hello_ascii:0:2}"
          debugme echo "tls_protocol: ${tls_hello_ascii:2:4}"

          lines_returned=$(count_lines "$(hexdump -ve '16/1 "%02x " " \n"' "$SOCK_REPLY_FILE")")
          debugme echo "lines HB reply: $lines_returned"

          if [[ $DEBUG -ge 3 ]]; then
               tmln_out "\nheartbleed reply: "
               hexdump -C "$SOCK_REPLY_FILE" | head -20
               [[ $lines_returned -gt 20 ]] && tmln_out "[...]"
               tmln_out
          fi

          if [[ $lines_returned -gt 1 ]] && [[ "${tls_hello_ascii:0:4}" == 1803 ]]; then
               if [[ "$STARTTLS_PROTOCOL" =~ ftp ]]; then
                    # check possibility of weird vsftpd reply, see #426, despite "1803" seems very unlikely...
                    if grep -q '500 OOPS' "$SOCK_REPLY_FILE" ; then
                         append=", successful weeded out vsftpd false positive"
                         pr_svrty_best "not vulnerable (OK)"; out "$append"
                         fileout "$jsonID" "OK" "not vulnerable $append" "$cve" "$cwe"
                    else
                         out "likely "
                         pr_svrty_critical "VULNERABLE (NOT ok)"
                         [[ $DEBUG -lt 3 ]] && tm_out ", use debug >=3 to confirm"
                         fileout "$jsonID" "CRITICAL" "VULNERABLE $cve" "$cwe" "$hint"
                    fi
               else
                    pr_svrty_critical "VULNERABLE (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "VULNERABLE $cve" "$cwe" "$hint"
               fi
          else
               pr_svrty_best "not vulnerable (OK)"
               fileout "$jsonID" "OK" "not vulnerable $cve" "$cwe"
          fi
     fi
     outln
     tmpfile_handle ${FUNCNAME[0]}.dd $SOCK_REPLY_FILE
     close_socket
     return 0
}

# helper function
ok_ids(){
     prln_svrty_best "\n ok -- something reset our ccs packets"
     return 0
}

# see https://www.openssl.org/news/secadv_20140605.txt
# mainly adapted from Ramon de C Valle's C code from https://gist.github.com/rcvalle/71f4b027d61a78c42607
#FIXME: At a certain point ccs needs to be changed and make use of code2network using a file, then tls_sockets
#
run_ccs_injection(){
     local tls_hexcode ccs_message client_hello byte6
     local -i retval ret=0
     local tls_hello_ascii=""
     local jsonID="CCS"
     local cve="CVE-2014-0224"
     local cwe="CWE-310"
     local hint=""

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for CCS injection vulnerability " && outln
     pr_bold " CCS"; out " ($cve)                       "

     if ( [[ "$STARTTLS_PROTOCOL" =~ ldap ]] || [[ "$STARTTLS_PROTOCOL" =~ irc ]] ); then
          prln_local_problem "STARTTLS/$STARTTLS_PROTOCOL and --ssl-native collide here"
          return 1
     fi

     if [[ 0 -eq $(has_server_protocol tls1) ]]; then
          tls_hexcode="x03, x01"
     elif [[ 0 -eq $(has_server_protocol tls1_1) ]]; then
          tls_hexcode="x03, x02"
     elif [[ 0 -eq $(has_server_protocol tls1_2) ]]; then
          tls_hexcode="x03, x03"
     elif [[ 0 -eq $(has_server_protocol ssl3) ]]; then
          tls_hexcode="x03, x00"
     else # no protocol for some reason defined, determine TLS versions offered with a new handshake
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY") >$TMPFILE 2>$ERRFILE </dev/null
          case "$(get_protocol $TMPFILE)" in
               *1.2)  tls_hexcode="x03, x03" ; add_tls_offered tls1_2 yes ;;
               *1.1)  tls_hexcode="x03, x02" ; add_tls_offered tls1_1 yes ;;
               TLSv1) tls_hexcode="x03, x01" ; add_tls_offered tls1 yes ;;
               SSLv3) tls_hexcode="x03, x00" ; add_tls_offered ssl3 yes ;;
          esac
     fi
     debugme echo "using protocol $tls_hexcode"

     ccs_message=", x14, $tls_hexcode ,x00, x01, x01"

     client_hello="
     # TLS header (5 bytes)
     ,x16,                         # content type (x16 for handshake)
     x03, x01,                     # TLS version in record layer is always TLS 1.0 (except SSLv3)
     x00, x93,                     # length
     # Handshake header
     x01,                          # type (x01 for ClientHello)
     x00, x00, x8f,                # length
     $tls_hexcode,                 # TLS version
     # Random (32 byte)
     x53, x43, x5b, x90, x9d, x9b, x72, x0b,
     xbc, x0c, xbc, x2b, x92, xa8, x48, x97,
     xcf, xbd, x39, x04, xcc, x16, x0b, x85,
     x03, x90, x9f, x77, x04, x33, xd4, xde,
     x00,                # session ID length
     x00, x68,           # cipher suites length
     # Cipher suites (51 suites)
     xc0, x13, xc0, x12, xc0, x11, xc0, x10,
     xc0, x0f, xc0, x0e, xc0, x0d, xc0, x0c,
     xc0, x0b, xc0, x0a, xc0, x09, xc0, x08,
     xc0, x07, xc0, x06, xc0, x05, xc0, x04,
     xc0, x03, xc0, x02, xc0, x01, x00, x39,
     x00, x38, x00, x37, x00, x36, x00, x35, x00, x34,
     x00, x33, x00, x32, x00, x31, x00, x30,
     x00, x2f, x00, x16, x00, x15, x00, x14,
     x00, x13, x00, x12, x00, x11, x00, x10,
     x00, x0f, x00, x0e, x00, x0d, x00, x0c,
     x00, x0b, x00, x0a, x00, x09, x00, x08,
     x00, x07, x00, x06, x00, x05, x00, x04,
     x00, x03, x00, x02, x00, x01, x01, x00"

     fd_socket 5 || return 1

# we now make a standard handshake ...
     debugme echo -n "sending client hello... "
     socksend "$client_hello" 1

     debugme echo "reading server hello... "
     sockread_serverhello 32768
     if [[ $DEBUG -ge 4 ]]; then
          hexdump -C "$SOCK_REPLY_FILE" | head -20
          tmln_out "[...]"
          tm_out "\nsending payload #1 with TLS version $tls_hexcode:  "
     fi
     rm "$SOCK_REPLY_FILE"
# ... and then send the a change cipher spec message
     socksend "$ccs_message" 1 || ok_ids
     sockread_serverhello 4096 $CCS_MAX_WAITSOCK
     if [[ $DEBUG -ge 3 ]]; then
          tmln_out "\n1st reply: "
          hexdump -C "$SOCK_REPLY_FILE" | head -20
          tmln_out
          tm_out "sending payload #2 with TLS version $tls_hexcode:  "
     fi
     rm "$SOCK_REPLY_FILE"

     socksend "$ccs_message" 2 || ok_ids
     sockread_serverhello 4096 $CCS_MAX_WAITSOCK
     retval=$?

     tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
     byte6="${tls_hello_ascii:12:2}"
     debugme echo "tls_content_type: ${tls_hello_ascii:0:2} | tls_protocol: ${tls_hello_ascii:2:4} | byte6: $byte6"

     if [[ $DEBUG -ge 3 ]]; then
          tmln_out "\n2nd reply: "
          hexdump -C "$SOCK_REPLY_FILE"
          tmln_out
     fi

# in general, see https://en.wikipedia.org/wiki/Transport_Layer_Security#Alert_protocol
#                 https://tools.ietf.org/html/rfc5246#section-7.2
#
# not ok for CCSI:  15 | 0301    | 00 02    | 02 15
#                ALERT | TLS 1.0 | Length=2 | Decryption failed (21)
#
# ok:   nothing: ==> RST
#
# 0A:      Unexpected message
# 28:      Handshake failure
     if [[ -z "${tls_hello_ascii:0:12}" ]]; then
          # empty reply
          pr_svrty_best "not vulnerable (OK)"
          if [[ $retval -eq 3 ]]; then
               fileout "$jsonID" "OK" "not vulnerable (timed out)" "$cve" "$cwe"
          else
               fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
          fi
     elif [[ "${tls_hello_ascii:0:4}" == "1503" ]]; then
          if [[ ! "${tls_hello_ascii:5:2}" =~ [03|02|01|00] ]]; then
               pr_warning "test failed "
               out "no proper TLS repy (debug info: protocol sent: 1503${tls_hexcode#x03, x}, reply: ${tls_hello_ascii:0:14}"
               fileout "$jsonID" "DEBUG" "test failed, around line $LINENO, debug info (${tls_hello_ascii:0:14})" "$cve" "$cwe" "$hint"
               ret=1
          elif [[ "$byte6" == "15" ]]; then
               # decryption failed received
               pr_svrty_critical "VULNERABLE (NOT ok)"
               fileout "$jsonID" "CRITICAL" "VULNERABLE" "$cve" "$cwe" "$hint"
          elif [[ "$byte6" == "0A" ]] || [[ "$byte6" == "28" ]]; then
               # Unexpected message / Handshake failure  received
               pr_warning "likely "
               out "not vulnerable (OK)"
               out " - alert description type: $byte6"
               fileout "$jsonID" "WARN" "probably not vulnerable but received 0x${byte6} instead of 0x15" "$cve" "$cwe" "$hint"
          elif [[ "$byte6" == "14" ]]; then
               # bad_record_mac -- this is not "not vulnerable"
               out "likely "
               pr_svrty_critical "VULNERABLE (NOT ok)"
               out ", suspicious \"bad_record_mac\" ($byte6)"
               fileout "$jsonID" "CRITICAL" "likely VULNERABLE" "$cve" "$cwe" "$hint"
          else
               # other errors, see https://tools.ietf.org/html/rfc5246#section-7.2
               out "likely "
               pr_svrty_critical "VULNERABLE (NOT ok)"
               out ", suspicious error code \"$byte6\" returned. Please report"
               fileout "$jsonID" "CRITICAL" "likely VULNERABLE with $byte6" "$cve" "$cwe" "$hint"
          fi
     elif [[ $STARTTLS_PROTOCOL == "mysql" ]] && [[ "${tls_hello_ascii:14:12}" == "233038533031" ]]; then
          # MySQL community edition (yaSSL) returns a MySQL error instead of a TLS Alert
          # Error: #08S01 Bad handshake
          pr_svrty_best "not vulnerable (OK)"
          out ", looks like MySQL community edition (yaSSL)"
          fileout "$jsonID" "OK" "not vulnerable (MySQL community edition (yaSSL) detected)" "$cve" "$cwe"
     elif [[ "$byte6" == [0-9a-f][0-9a-f] ]] && [[ "${tls_hello_ascii:2:2}" != "03" ]]; then
          pr_warning "test failed"
          out ", probably read buffer too small (${tls_hello_ascii:0:14})"
          fileout "$jsonID" "DEBUG" "test failed, probably read buffer too small (${tls_hello_ascii:0:14})" "$cve" "$cwe" "$hint"
          ret=1
     else
          pr_warning "test failed "
          out "around line $LINENO (debug info: ${tls_hello_ascii:0:12},$byte6)"
          fileout "$jsonID" "DEBUG" "test failed, around line $LINENO, debug info (${tls_hello_ascii:0:12},$byte6)" "$cve" "$cwe" "$hint"
          ret=1
     fi
     outln

     tmpfile_handle ${FUNCNAME[0]}.dd $SOCK_REPLY_FILE
     close_socket
     return $ret
}

sub_session_ticket_tls() {
     local sessticket_tls=""
     #FIXME: we likely have done this already before (either @ run_server_defaults() or at least the output
     #       from a previous handshake) --> would save 1x connect. We have TLS_TICKET but not yet the ticket itself #FIXME
     #ATTENTION: we DO NOT use SNI here as we assume ticketbleed is a vulnerability of the TLS stack. If we'd do SNI here, we'd also need
     #           it in the ClientHello of run_ticketbleed() otherwise the ticket will be different and the whole thing won't work!
     #
     sessticket_tls="$($OPENSSL s_client $(s_client_options "$BUGS $OPTIMAL_PROTO $PROXY -connect $NODEIP:$PORT") </dev/null 2>$ERRFILE | awk '/TLS session ticket:/,/^$/' | awk '!/TLS session ticket/')"
     sessticket_tls="$(sed -e 's/^.* - /x/g' -e 's/  .*$//g' <<< "$sessticket_tls" | tr '\n' ',')"
     sed -e 's/ /,x/g' -e 's/-/,x/g' <<< "$sessticket_tls"

}


# see https://blog.filippo.io/finding-ticketbleed/ |  http://ticketbleed.com/
run_ticketbleed() {
     local session_tckt_tls=""
     local -i len_ch=300                            # fixed len of prepared clienthello below
     local sid="x00,x0B,xAD,xC0,xDE,x00,"           # some abitratry bytes
     local len_sid="$(( ${#sid} / 4))"
     local xlen_sid="$(dec02hex $len_sid)"
     local -i len_tckt_tls=0 nr_sid_detected=0
     local xlen_tckt_tls="" xlen_handshake_record_layer="" xlen_handshake_ssl_layer=""
     local -i len_handshake_record_layer=0
     local i
     local -a memory sid_detected
     local early_exit=true
     local -i ret=0
     local jsonID="ticketbleed"
     local cve="CVE-2016-9244"
     local cwe="CWE-200"
     local hint=""

     [[ -n "$STARTTLS" ]] && return 0
     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for Ticketbleed vulnerability " && outln
     pr_bold " Ticketbleed"; out " ($cve), experiment.  "

     if [[ "$SERVICE" != HTTP ]] && ! "$CLIENT_AUTH"; then
          outln "--   (applicable only for HTTPS)"
          fileout "$jsonID" "INFO" "not applicable, not HTTP" "$cve" "$cwe"
          return 0
     fi

     # highly unlikely that it is NOT supported. We may loose time here but it's more solid
     [[ -z "$TLS_EXTENSIONS" ]] && determine_tls_extensions
     if [[ ! "${TLS_EXTENSIONS}" =~ "session ticket" ]]; then
          pr_svrty_best "not vulnerable (OK)"
          outln ", no session ticket extension"
          fileout "$jsonID" "OK" "no session ticket extension" "$cve" "$cwe"
          return 0
     fi

     if [[ 0 -eq $(has_server_protocol tls1) ]]; then
          tls_hexcode="x03, x01"
     elif [[ 0 -eq $(has_server_protocol tls1_1) ]]; then
          tls_hexcode="x03, x02"
     elif [[ 0 -eq $(has_server_protocol tls1_2) ]]; then
          tls_hexcode="x03, x03"
     elif [[ 0 -eq $(has_server_protocol ssl3) ]]; then
          tls_hexcode="x03, x00"
     else # no protocol for some reason defined, determine TLS versions offered with a new handshake
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY") >$TMPFILE 2>$ERRFILE </dev/null
          case "$(get_protocol $TMPFILE)" in
               *1.2)  tls_hexcode="x03, x03" ; add_tls_offered tls1_2 yes ;;
               *1.1)  tls_hexcode="x03, x02" ; add_tls_offered tls1_1 yes ;;
               TLSv1) tls_hexcode="x03, x01" ; add_tls_offered tls1 yes ;;
               SSLv3) tls_hexcode="x03, x00" ; add_tls_offered ssl3 yes ;;
          esac
     fi
     debugme echo "using protocol $tls_hexcode"

     session_tckt_tls="$(sub_session_ticket_tls)"
     if [[ "$session_tckt_tls" == "," ]]; then
          pr_svrty_best "not vulnerable (OK)"
          outln ", no session tickets"
          fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
          debugme echo " session ticket TLS \"$session_tckt_tls\""
          return 0
     fi

     len_tckt_tls=${#session_tckt_tls}
     len_tckt_tls=$(( len_tckt_tls / 4))
     xlen_tckt_tls="$(dec02hex $len_tckt_tls)"
     len_handshake_record_layer="$(( len_sid + len_ch + len_tckt_tls ))"
     xlen_handshake_record_layer="$(dec04hex "$len_handshake_record_layer")"
     len_handshake_ssl_layer="$(( len_handshake_record_layer + 4 ))"
     xlen_handshake_ssl_layer="$(dec04hex "$len_handshake_ssl_layer")"

     if [[ "$DEBUG" -ge 4 ]]; then
          echo "len_tckt_tls (hex):            $len_tckt_tls ($xlen_tckt_tls)"
          echo "sid:                           $sid"
          echo "len_sid (hex)                  $len_sid ($xlen_sid)"
          echo "len_handshake_record_layer:    $len_handshake_record_layer ($xlen_handshake_record_layer)"
          echo "len_handshake_ssl_layer:       $len_handshake_ssl_layer ($xlen_handshake_ssl_layer)"
          echo "session_tckt_tls:              $session_tckt_tls"
     fi

     client_hello="
     # TLS header (5 bytes)
     ,x16,               # Content type (x16 for handshake)
     x03,x01,            # TLS version record layer
                         # Length Secure Socket Layer follows:
     $xlen_handshake_ssl_layer,
     # Handshake header
     x01,                # Type (x01 for ClientHello)
                         # Length of ClientHello follows:
     x00, $xlen_handshake_record_layer,
     $tls_hexcode,        # TLS Version
     # Random (32 byte) Unix time etc, see www.moserware.com/2009/06/first-few-milliseconds-of-https.html
     xee, xee, x5b, x90, x9d, x9b, x72, x0b,
     xbc, x0c, xbc, x2b, x92, xa8, x48, x97,
     xcf, xbd, x39, x04, xcc, x16, x0b, x85,
     x03, x90, x9f, x77, x04, x33, xff, xff,
     $xlen_sid,          # Session ID length
     $sid
     x00, x6a,           # Cipher suites length 106
     # 53 Cipher suites
     xc0,x14, xc0,x13, xc0,x0a, xc0,x21,
     x00,x39, x00,x38, x00,x88, x00,x87,
     xc0,x0f, xc0,x05, x00,x35, x00,x84,
     xc0,x12, xc0,x08, xc0,x1c, xc0,x1b,
     x00,x16, x00,x13, xc0,x0d, xc0,x03,
     x00,x0a, xc0,x13, xc0,x09, xc0,x1f,
     xc0,x1e, x00,x33, x00,x32, x00,x9a,
     x00,x99, x00,x45, x00,x44, xc0,x0e,
     xc0,x04, x00,x2f, x00,x96, x00,x41,
     xc0,x11, xc0,x07, xc0,x0c, xc0,x02,
     x00,x05, x00,x04, x00,x15, x00,x12,
     xc0,x30, xc0,x2f, x00,x9d, x00,x9c,
     x00,x3d, x00,x3c, x00,x9f, x00,x9e,
     x00,xff,
     x01,               # Compression methods length
     x00,               # Compression method (x00 for NULL)
     x01,x5b,           # Extensions length    ####### 10b + x14 + x3c
# Extension Padding
     x00,x15,
     # length:
     x00,x38,
     x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00,
     x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00,
     x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00, x00,x00,
# Extension: ec_point_formats
     x00,x0b,
     # length:
     x00,x04,
     # data:
     x03,x00, x01,x02,
# Extension: elliptic_curves
     x00,x0a,
     # length
     x00,x34,
     x00,x32,
     # data:
     x00,x0e, x00,x0d, x00,x19, x00,x0b, x00,x0c,
     x00,x18, x00,x09, x00,x0a, x00,x16,
     x00,x17, x00,x08, x00,x06, x00,x07,
     x00,x14, x00,x15, x00,x04, x00,x05,
     x00,x12, x00,x13, x00,x01, x00,x02,
     x00,x03, x00,x0f, x00,x10, x00,x11,
# Extension: Signature Algorithms
     x00,x0d,
     # length:
     x00,x10,
     # data:
     x00,x0e ,x04,x01, x05,x01 ,x02,x01, x04,x03, x05,x03,
     x02,x03, x02,x02,
# Extension: SessionTicket TLS
     x00, x23,
     # length of SessionTicket TLS
     x00, $xlen_tckt_tls,
     # data, Session Ticket
     $session_tckt_tls                       # here we have the comma already
# Extension: Heartbeat
     x00, x0f, x00, x01, x01"

     # we do 3 client hellos, then see whether different memory is returned
     for i in 1 2 3; do
          fd_socket 5 || return 6
          debugme echo -n "sending client hello... "
          socksend "$client_hello" 0

          debugme echo "reading server hello (ticketbleed reply)... "
          if "$FAST_SOCKET"; then
               tls_hello_ascii=$(sockread_fast 32768)
          else
               sockread_serverhello 32768 $CCS_MAX_WAITSOCK
               tls_hello_ascii=$(hexdump -v -e '16/1 "%02X"' "$SOCK_REPLY_FILE")
          fi
          [[ "$DEBUG" -ge 5 ]] && echo "$tls_hello_ascii"
          if [[ "$DEBUG" -ge 4 ]]; then
               echo "============================="
               echo "$tls_hello_ascii"
               echo "============================="
          fi

          if [[ "${tls_hello_ascii:0:2}" == 15 ]]; then
               debugme echo -n "TLS Alert ${tls_hello_ascii:10:4} (TLS version: ${tls_hello_ascii:2:4}) -- "
               pr_svrty_best "not vulnerable (OK)"
               fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
               send_close_notify "${tls_hello_ascii:18:4}"
               close_socket
               break
          elif [[ -z "${tls_hello_ascii:0:2}" ]]; then
               pr_svrty_best "not vulnerable (OK)"
               out ", reply empty"
               fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
               send_close_notify "${tls_hello_ascii:18:4}"
               close_socket
               break
          elif [[ "${tls_hello_ascii:0:2}" == 16 ]]; then
               early_exit=false
               debugme echo -n "Handshake (TLS version: ${tls_hello_ascii:2:4}), "
               if [[ "${tls_hello_ascii:10:6}" == 020000 ]]; then
                    debugme echo -n "ServerHello -- "
               else
                    debugme echo -n "Message type: ${tls_hello_ascii:10:6} -- "
               fi
               sid_input=$(sed -e 's/x//g' -e 's/,//g' <<< "$sid")
               sid_detected[i]="${tls_hello_ascii:88:32}"
               memory[i]="${tls_hello_ascii:$((88+ len_sid*2)):$((32 - len_sid*2))}"
               if [[ "$DEBUG" -ge 3 ]]; then
                    echo
                    echo "TLS version, record layer: ${tls_hello_ascii:18:4}"
                    echo "Session ID:                ${sid_detected[i]}"
                    echo "memory:                    ${memory[i]}"
                    echo -n "$sid_input in SID:       " ;
                         [[ "${sid_detected[i]}"  =~ $sid_input ]] && echo "yes" || echo "no"
               fi
               [[ "$DEBUG" -ge 1 ]] && echo $tls_hello_ascii >$TEMPDIR/${FUNCNAME[0]}.tls_hello_ascii${i}.txt
          else
               ret=1
               pr_warning "test failed"
               out " around line $LINENO (debug info: ${tls_hello_ascii:0:2}, ${tls_hello_ascii:2:10})"
               fileout "$jsonID" "DEBUG" "test failed, around $LINENO (debug info: ${tls_hello_ascii:0:2}, ${tls_hello_ascii:2:10})" "$cve" "$cwe"
               send_close_notify "${tls_hello_ascii:18:4}"
               close_socket
               break
          fi
          send_close_notify "${tls_hello_ascii:18:4}"
          close_socket
     done

     if ! "$early_exit"; then
          # here we test the replies if a TLS server hello was received >1x
          for i in 1 2 3 ; do
               if [[ "${sid_detected[i]}" =~ $sid_input ]]; then
                    # was our faked TLS SID returned?
                    nr_sid_detected+=1
               fi
          done
          if [[ $nr_sid_detected -eq 3 ]]; then
               if [[ ${memory[1]} != ${memory[2]} ]] && [[ ${memory[2]} != ${memory[3]} ]]; then
                    pr_svrty_critical "VULNERABLE (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "VULNERABLE" "$cve" "$cwe" "$hint"
               else
                    pr_svrty_best "not vulnerable (OK)"
                    out ", session IDs were returned but potential memory fragments do not differ"
                    fileout "$jsonID" "OK" "not vulnerable, returned potential memory fragments do not differ" "$cve" "$cwe"
               fi
          else
               if [[ "$DEBUG" -ge 2 ]]; then
                    echo
                    pr_warning "test failed, non reproducible results!"
               else
                    pr_warning "test failed, non reproducible results!"
                    out " Please run again w \"--debug=2\"  (# of faked TLS SIDs detected: $nr_sid_detected)"
               fi
               fileout "$jsonID" "DEBUG" "test failed, non reproducible results. $nr_sid_detected TLS Session IDs $nr_sid_detected, ${sid_detected[1]},${sid_detected[2]},${sid_detected[3]}" "$cve" "$cwe"
               ret=1
          fi
     fi
     outln
     return $ret
}

# Overview @ http://www.exploresecurity.com/wp-content/uploads/custom/SSL_manual_cheatsheet.html
#
run_renego() {
     local legacycmd="" proto="$OPTIMAL_PROTO"
     local sec_renego sec_client_renego
     local -i ret=0
     local cve=""
     local cwe="CWE-310"
     local hint=""
     local jsonID=""
     # No SNI needed here as there won't be two different SSL stacks for one IP

     "$HAS_TLS13" && [[ -z "$proto" ]] && proto="-no_tls1_3"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for Renegotiation vulnerabilities " && outln

     pr_bold " Secure Renegotiation (RFC 5746)           "
     jsonID="secure_renego"
     # first fingerprint for the Line "Secure Renegotiation IS NOT" or "Secure Renegotiation IS "
     $OPENSSL s_client $(s_client_options "$proto $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY") 2>&1 </dev/null >$TMPFILE 2>$ERRFILE
     if sclient_connect_successful $? $TMPFILE; then
          grep -iaq "Secure Renegotiation IS NOT" $TMPFILE
          sec_renego=$?                                                    # 0= Secure Renegotiation IS NOT supported
          # grep -iaq "Secure Renegotiation IS supported"
          #FIXME: didn't occur to me yet but why not also to check on "Secure Renegotiation IS supported"
          case $sec_renego in
               0)   prln_svrty_critical "Not supported / VULNERABLE (NOT ok)"
                    fileout "$jsonID" "CRITICAL" "VULNERABLE" "$cve" "$cwe" "$hint"
                    ;;
               1)   prln_svrty_best "supported (OK)"
                    fileout "$jsonID" "OK" "supported" "$cve" "$cwe"
                    ;;
               *)   prln_warning "FIXME (bug): $sec_renego"
                    fileout "$jsonID" "WARN" "FIXME (bug) $sec_renego" "$cve" "$cwe"
                    ;;
          esac
     else
          prln_warning "OpenSSL handshake didn't succeed"
          fileout "$jsonID" "WARN" "OpenSSL handshake didn't succeed" "$cve" "$cwe"
     fi

     # FIXME: Basically this can be done with sockets and we might have that information already
     # see https://tools.ietf.org/html/rfc5746#section-3.4: 'The client MUST include either an empty "renegotiation_info"
     # extension, or the TLS_EMPTY_RENEGOTIATION_INFO_SCSV signaling cipher suite value in the ClientHello. [..]
     # When a ServerHello is received, the client MUST check if it includes the "renegotiation_info" extension:
     # If the extension is not present, the server does not support secure renegotiation'


     pr_bold " Secure Client-Initiated Renegotiation     "
     jsonID="secure_client_renego"
     cve="CVE-2011-1473"
     # see: https://blog.qualys.com/ssllabs/2011/10/31/tls-renegotiation-and-denial-of-service-attacks
     #      http://blog.ivanristic.com/2009/12/testing-for-ssl-renegotiation.html -- head/get doesn't seem to be needed though
     #      https://archive.fo/20130415224936/http://www.thc.org/thc-ssl-dos/, https://vincent.bernat.ch/en/blog/2011-ssl-dos-mitigation
     case "$OSSL_VER" in
          0.9.8*)             # we need this for Mac OSX unfortunately
               case "$OSSL_VER_APPENDIX" in
                    [a-l])
                         prln_local_problem " Your $OPENSSL cannot test this secure renegotiation vulnerability"
                         fileout "$jsonID" "WARN" "your $OPENSSL cannot test this secure renegotiation vulnerability" "$cve" "$cwe"
                         return 1
                         ;;
                    [m-z])
                         ;; # all ok
               esac
               ;;
          1.0.1*|1.0.2*)
               legacycmd="-legacy_renegotiation"
               ;;
          0.9.9*|1.0*|1.1*)
               ;;   # all ok
     esac


     if "$CLIENT_AUTH"; then
          prln_warning "client x509-based authentication prevents this from being tested"
          fileout "$jsonID" "WARN" "client x509-based authentication prevents this from being tested"
          sec_client_renego=1
     else
          # We need up to two tries here, as some LiteSpeed servers don't answer on "R" and block. Thus first try in the background
          # msg enables us to look deeper into it while debugging
          echo R | $OPENSSL s_client $(s_client_options "$proto $BUGS $legacycmd $STARTTLS -msg -connect $NODEIP:$PORT $PROXY") >$TMPFILE 2>>$ERRFILE &
          wait_kill $! $HEADER_MAXSLEEP
          if [[ $? -eq 3 ]]; then
               pr_svrty_good "likely not vulnerable (OK)"; outln ", timed out"        # it hung
               fileout "$jsonID" "OK" "likely not vulnerable (timed out)" "$cve" "$cwe"
               sec_client_renego=1
          else
               # second try in the foreground as we are sure now it won't hang
               echo R | $OPENSSL s_client $(s_client_options "$proto $legacycmd $STARTTLS $BUGS -msg -connect $NODEIP:$PORT $PROXY") >$TMPFILE 2>>$ERRFILE
               sec_client_renego=$?                                                  # 0=client is renegotiating & doesn't return an error --> vuln!
               case "$sec_client_renego" in
                    0)   if [[ $SERVICE == HTTP ]]; then
                              pr_svrty_high "VULNERABLE (NOT ok)"; outln ", DoS threat"
                              fileout "$jsonID" "HIGH" "VULNERABLE, DoS threat" "$cve" "$cwe" "$hint"
                         else
                              pr_svrty_medium "VULNERABLE (NOT ok)"; outln ", potential DoS threat"
                              fileout "$jsonID" "MEDIUM" "VULNERABLE, potential DoS threat" "$cve" "$cwe" "$hint"
                         fi
                         ;;
                    1)
                         prln_svrty_good "not vulnerable (OK)"
                         fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
                         ;;
                    *)
                         prln_warning "FIXME (bug): $sec_client_renego"
                         fileout "$jsonID" "DEBUG" "FIXME (bug) $sec_client_renego - Please report" "$cve" "$cwe"
                         ret=1
                         ;;
               esac
          fi
     fi

     #pr_bold " Insecure Client-Initiated Renegotiation  "  # pre-RFC 5746, CVE-2009-3555
     #jsonID="insecure_client_renego"
     #
     # https://www.openssl.org/news/vulnerabilities.html#y2009. It can only be tested with OpenSSL <=0.9.8k
     # Insecure Client-Initiated Renegotiation is missing ==> sockets. When we complete the handshake ;-)

     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}

run_crime() {
     local -i ret=0 sclient_success
     local addcmd=""
     local cve="CVE-2012-4929"
     local cwe="CWE-310"
     local hint=""

     # in a nutshell: don't offer TLS/SPDY compression on the server side
     # This tests for CRIME Vulnerability (www.ekoparty.org/2012/juliano-rizzo.php) on HTTPS, not SPDY (yet)
     # Please note that it is an attack where you need client side control, so in regular situations this
     # means anyway "game over", w/wo CRIME
     # www.h-online.com/security/news/item/Vulnerability-in-SSL-encryption-is-barely-exploitable-1708604.html

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for CRIME vulnerability " && outln
     pr_bold " CRIME, TLS " ; out "($cve)                "

     if ! "$HAS_ZLIB"; then
          if "$SSL_NATIVE"; then
               prln_local_problem "$OPENSSL lacks zlib support"
               fileout "CRIME_TLS" "WARN" "CRIME, TLS: Not tested. $OPENSSL lacks zlib support" "$cve" "$cwe"
               return 1
          else
               tls_sockets "03" "$TLS12_CIPHER" "" "" "true"
               sclient_success=$?
               [[ $sclient_success -eq 2 ]] && sclient_success=0
               [[ $sclient_success -eq 0 ]] && cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
          fi
     else
          [[ "$OSSL_VER" == 0.9.8* ]] && addcmd="-no_ssl2"
          "$HAS_TLS13" && [[ -z "$OPTIMAL_PROTO" ]] && addcmd+=" -no_tls1_3"
          $OPENSSL s_client $(s_client_options "$OPTIMAL_PROTO $BUGS -comp $addcmd $STARTTLS -connect $NODEIP:$PORT $PROXY $SNI") </dev/null &>$TMPFILE
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
     fi
     if [[ $sclient_success -ne 0 ]]; then
          pr_warning "test failed (couldn't connect)"
          fileout "CRIME_TLS" "WARN" "Check failed, couldn't connect" "$cve" "$cwe"
          ret=1
     elif grep -a Compression $TMPFILE | grep -aq NONE >/dev/null; then
          pr_svrty_good "not vulnerable (OK)"
          if [[ $SERVICE != "HTTP" ]] && ! "$CLIENT_AUTH";  then
               out " (not using HTTP anyway)"
               fileout "CRIME_TLS" "OK" "not vulnerable (not using HTTP anyway)" "$cve" "$cwe"
          else
               fileout "CRIME_TLS" "OK" "not vulnerable" "$cve" "$cwe"
          fi
     else
          if [[ $SERVICE == "HTTP" ]] || "$CLIENT_AUTH"; then
               pr_svrty_high "VULNERABLE (NOT ok)"
               fileout "CRIME_TLS" "HIGH" "VULNERABLE" "$cve" "$cwe" "$hint"
          else
               pr_svrty_medium "VULNERABLE but not using HTTP: probably no exploit known"
               fileout "CRIME_TLS" "MEDIUM" "VULNERABLE, but not using HTTP. Probably no exploit known" "$cve" "$cwe" "$hint"
               # not clear whether a protocol != HTTP offers the ability to repeatedly modify the input
               # which is done e.g. via javascript in the context of HTTP
          fi
     fi
     outln

# this needs to be re-done i order to remove the redundant check for spdy

     # weed out starttls, spdy-crime is a web thingy
#    if [[ "x$STARTTLS" != "x" ]]; then
#         echo
#         return $ret
#    fi

     # weed out non-webports, spdy-crime is a web thingy. there's a catch thoug, you see it?
#    case $PORT in
#         25|465|587|80|110|143|993|995|21)
#         echo
#         return $ret
#    esac

#    if "$HAS_NPN"; then
#         $OPENSSL s_client -host $NODE -port $PORT -nextprotoneg $NPN_PROTOs  $SNI </dev/null 2>/dev/null >$TMPFILE
#         if [[ $? -eq 0 ]]; then
#              echo
#              pr_bold "CRIME Vulnerability, SPDY " ; outln "($cve): "

#              STR=$(grep Compression $TMPFILE )
#              if echo $STR | grep -q NONE >/dev/null; then
#                   pr_svrty_best "not vulnerable (OK)"
#                   ret=$((ret + 0))
#              else
#                   pr_svrty_critical "VULNERABLE (NOT ok)"
#                   ret=$((ret + 1))
#              fi
#         fi
#    fi
#    [[ $DEBUG -ge 2 ]] tmln_out "$STR"
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}


# BREACH is a HTTP-level compression & an attack which works against any cipher suite and is agnostic
# to the version of TLS/SSL, more: http://www.breachattack.com/ . Foreign referrers are the important thing here!
# Mitigation: see https://community.qualys.com/message/20360
#
run_breach() {
     local header
     local -i ret=0
     local -i was_killed=0
     local referer useragent
     local url="$1"
     local spaces="                                          "
     local disclaimer=""
     local when_makesense=" Can be ignored for static pages or if no secrets in the page"
     local cve="CVE-2013-3587"
     local cwe="CWE-310"
     local hint=""
     local jsonID="BREACH"

     [[ $SERVICE != HTTP ]] && ! "$CLIENT_AUTH" && return 7

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for BREACH (HTTP compression) vulnerability " && outln
     pr_bold " BREACH"; out " ($cve)                    "
     if "$CLIENT_AUTH"; then
          outln "cannot be tested (server side requires x509 authentication)"
          fileout "$jsonID" "INFO" "was not tested, server side requires x509 authentication" "$cve" "$cwe"
     fi

     # if [[ $NR_HEADER_FAIL -ge $MAX_HEADER_FAIL ]]; then
     #      pr_warning "Retrieving HTTP header failed before. Skipping."
     #      fileout "$jsonID" "WARN" "HTTP response was wampty before" "$cve" "$cwe"
     #      outln
     #      return 1
     # fi

     [[ -z "$url" ]] && url="/"
     disclaimer=" - only supplied \"$url\" tested"

     referer="https://google.com/"
     [[ "$NODE" =~ google ]] && referer="https://yandex.ru/"     # otherwise we have a false positive for google.com
     useragent="$UA_STD"
     $SNEAKY && useragent="$UA_SNEAKY"
     printf "GET $url HTTP/1.1\r\nHost: $NODE\r\nUser-Agent: $useragent\r\nReferer: $referer\r\nConnection: Close\r\nAccept-encoding: gzip,deflate,compress\r\nAccept: text/*\r\n\r\n" | $OPENSSL s_client $(s_client_options "$OPTIMAL_PROTO $BUGS -quiet -ign_eof -connect $NODEIP:$PORT $PROXY $SNI") 1>$TMPFILE 2>$ERRFILE &
     wait_kill $! $HEADER_MAXSLEEP
     was_killed=$?                           # !=0 was killed
     result=$(awk '/^Content-Encoding/ { print $2 }' $TMPFILE)
     result=$(strip_lf "$result")
     debugme grep '^Content-Encoding' $TMPFILE
     if [[ ! -s $TMPFILE ]]; then
          pr_warning "failed (HTTP header request stalled or empty return"
          if [[ $was_killed -ne 0 ]]; then
               pr_warning " and was terminated"
               fileout "$jsonID" "WARN" "Test failed as HTTP request stalled and was terminated" "$cve" "$cwe"
          else
               fileout "$jsonID" "WARN" "Test failed as HTTP response was empty" "$cve" "$cwe"
          fi
          prln_warning ") "
          ret=1
     elif [[ -z $result ]]; then
          pr_svrty_best "no HTTP compression (OK) "
          outln "$disclaimer"
          fileout "$jsonID" "OK" "not vulnerable, no HTTP compression $disclaimer" "$cve" "$cwe"
     else
          pr_svrty_high "potentially NOT ok, uses $result HTTP compression."
          outln "$disclaimer"
          outln "$spaces$when_makesense"
          fileout "$jsonID" "HIGH" "potentially VULNERABLE, uses $result HTTP compression $disclaimer" "$cve" "$cwe" "$hint"
     fi
     # Any URL can be vulnerable. I am testing now only the given URL!

     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}


# SWEET32 (https://sweet32.info/). Birthday attacks on 64-bit block ciphers.
# In a nutshell: don't use 3DES ciphers anymore (DES, RC2 and IDEA too).
# Please note as opposed to RC4 (stream cipher) RC2 is a block cipher.
#
run_sweet32() {
     local -i sclient_success=1
     local sweet32_ciphers="IDEA-CBC-SHA:IDEA-CBC-MD5:RC2-CBC-MD5:KRB5-IDEA-CBC-SHA:KRB5-IDEA-CBC-MD5:ECDHE-RSA-DES-CBC3-SHA:ECDHE-ECDSA-DES-CBC3-SHA:SRP-DSS-3DES-EDE-CBC-SHA:SRP-RSA-3DES-EDE-CBC-SHA:SRP-3DES-EDE-CBC-SHA:EDH-RSA-DES-CBC3-SHA:EDH-DSS-DES-CBC3-SHA:DH-RSA-DES-CBC3-SHA:DH-DSS-DES-CBC3-SHA:AECDH-DES-CBC3-SHA:ADH-DES-CBC3-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-ECDSA-DES-CBC3-SHA:DES-CBC3-SHA:DES-CBC3-MD5:DES-CBC3-SHA:RSA-PSK-3DES-EDE-CBC-SHA:PSK-3DES-EDE-CBC-SHA:KRB5-DES-CBC3-SHA:KRB5-DES-CBC3-MD5:ECDHE-PSK-3DES-EDE-CBC-SHA:DHE-PSK-3DES-EDE-CBC-SHA:DES-CFB-M1:EXP1024-DHE-DSS-DES-CBC-SHA:EDH-RSA-DES-CBC-SHA:EDH-DSS-DES-CBC-SHA:DH-RSA-DES-CBC-SHA:DH-DSS-DES-CBC-SHA:ADH-DES-CBC-SHA:EXP1024-DES-CBC-SHA:DES-CBC-SHA:EXP1024-RC2-CBC-MD5:DES-CBC-MD5:DES-CBC-SHA:KRB5-DES-CBC-SHA:KRB5-DES-CBC-MD5:EXP-EDH-RSA-DES-CBC-SHA:EXP-EDH-DSS-DES-CBC-SHA:EXP-ADH-DES-CBC-SHA:EXP-DES-CBC-SHA:EXP-RC2-CBC-MD5:EXP-RC2-CBC-MD5:EXP-KRB5-RC2-CBC-SHA:EXP-KRB5-DES-CBC-SHA:EXP-KRB5-RC2-CBC-MD5:EXP-KRB5-DES-CBC-MD5:EXP-DH-DSS-DES-CBC-SHA:EXP-DH-RSA-DES-CBC-SHA"
     local sweet32_ciphers_hex="00,07, 00,21, 00,25, c0,12, c0,08, c0,1c, c0,1b, c0,1a, 00,16, 00,13, 00,10, 00,0d, c0,17, 00,1b, c0,0d, c0,03, 00,0a, 00,93, 00,8b, 00,1f, 00,23, c0,34, 00,8f, fe,ff, ff,e0, 00,63, 00,15, 00,12, 00,0f, 00,0c, 00,1a, 00,62, 00,09, 00,61, 00,1e, 00,22, fe,fe, ff,e1, 00,14, 00,11, 00,19, 00,08, 00,06, 00,27, 00,26, 00,2a, 00,29, 00,0b, 00,0e"
     local ssl2_sweet32_ciphers='RC2-CBC-MD5:EXP-RC2-CBC-MD5:IDEA-CBC-MD5:DES-CBC-MD5:DES-CBC-SHA:DES-CBC3-MD5:DES-CBC3-SHA:DES-CFB-M1'
     local ssl2_sweet32_ciphers_hex='03,00,80, 04,00,80, 05,00,80, 06,00,40, 06,01,40, 07,00,C0, 07,01,C0, FF,80,00'
     local nr_cipher_minimal=21
     local proto
     local cve="CVE-2016-2183 CVE-2016-6329"
     local cwe="CWE-327"
     local hint=""
     local -i nr_sweet32_ciphers=0 nr_supported_ciphers=0 nr_ssl2_sweet32_ciphers=0 nr_ssl2_supported_ciphers=0
     local ssl2_sweet=false
     local using_sockets=true

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for SWEET32 (Birthday Attacks on 64-bit Block Ciphers)       " && outln
     pr_bold " SWEET32"; out " (${cve// /, })    "

     "$SSL_NATIVE" && using_sockets=false
     # The openssl binary distributed has almost everything we need (PSK, KRB5 ciphers and feff, ffe0 are typically missing).
     # Measurements show that there's little impact whether we use sockets or TLS here, so the default is sockets here
     if "$using_sockets"; then
          for proto in 03 02 01 00; do
               "$FAST" && [[ "$proto" != 03 ]] && break
               ! "$FAST" && [[ $(has_server_protocol "$proto") -eq 1 ]] && continue
               tls_sockets "$proto" "${sweet32_ciphers_hex}, 00,ff"
               sclient_success=$?
               [[ $sclient_success -eq 2 ]] && sclient_success=0
               [[ $sclient_success -eq 0 ]] && break
          done
          if [[ 1 -ne $(has_server_protocol "ssl2") ]]; then
               sslv2_sockets "$ssl2_sweet32_ciphers_hex"
               case $? in
                    3)   ssl2_sweet=true
                         add_tls_offered ssl2 yes ;;
                    0)   ;; # ssl2_sweet=false
                    1|4|6|7)  debugme "${FUNCNAME[0]}: test problem we don't handle here"
                         ;;
               esac
          fi
     else
          nr_sweet32_ciphers=$(count_ciphers $sweet32_ciphers)
          nr_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $sweet32_ciphers))
          debugme echo "$nr_sweet32_ciphers / $nr_supported_ciphers"

          nr_ssl2_sweet32_ciphers=$(count_ciphers $ssl2_sweet32_ciphers)
          nr_ssl2_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $ssl2_sweet32_ciphers))
          debugme echo "$nr_ssl2_sweet32_ciphers / $nr_ssl2_supported_ciphers"

          if [[ $(( nr_supported_ciphers + nr_ssl2_supported_ciphers )) -le $nr_cipher_minimal ]]; then
               pr_local_problem "Only ${nr_supported_ciphers}+${nr_ssl2_supported_ciphers} \"SWEET32 ciphers\" found in your $OPENSSL."
               outln " Test skipped"
               fileout "SWEET32" "WARN" "Not tested, lack of local support ($((nr_supported_ciphers + nr_ssl2_supported_ciphers)) ciphers only)" "$cve" "$cwe" "$hint"
               return 1
          fi
          for proto in -no_ssl2 -tls1_1 -tls1 -ssl3; do
               [[ $nr_supported_ciphers -eq 0 ]] && break
               ! "$HAS_SSL3" && [[ "$proto" == -ssl3 ]] && continue
               if [[ "$proto" != -no_ssl2 ]]; then
                    "$FAST" && break
                    [[ $(has_server_protocol "${proto:1}") -eq 1 ]] && continue
               fi
               $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS $proto -cipher $sweet32_ciphers -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
               sclient_connect_successful $? $TMPFILE
               sclient_success=$?
               [[ $DEBUG -ge 2 ]] && grep -Eq "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
               [[ $sclient_success -eq 0 ]] && break
          done
          if "$HAS_SSL2"; then
               if [[ 1 -ne $(has_server_protocol "ssl2") ]]; then
                    $OPENSSL s_client $STARTTLS $BUGS -ssl2 -cipher $ssl2_sweet32_ciphers -connect $NODEIP:$PORT $PROXY >$TMPFILE 2>$ERRFILE </dev/null
                    sclient_connect_successful $? $TMPFILE
                    if [[ $? -eq 0 ]]; then
                         ssl2_sweet=true
                         add_tls_offered ssl2 yes
                    fi
               fi
          else
               debugme tm_warning "Can't test with SSLv2 here as $OPENSSL lacks support"
               #  we omit adding a string for DEBUG==0 here as using sockets is the default and the following elif statement becomes ugly
          fi
     fi
     if [[ $sclient_success -eq 0 ]] && "$ssl2_sweet" ; then
          pr_svrty_low "VULNERABLE"; out ", uses 64 bit block ciphers for SSLv2 and above"
          fileout "SWEET32" "LOW" "uses 64 bit block ciphers for SSLv2 and above" "$cve" "$cwe" "$hint"
     elif [[ $sclient_success -eq 0 ]]; then
          pr_svrty_low "VULNERABLE"; out ", uses 64 bit block ciphers"
          fileout "SWEET32" "LOW" "uses 64 bit block ciphers" "$cve" "$cwe" "$hint"
     elif "$ssl2_sweet"; then
          pr_svrty_low "VULNERABLE"; out ", uses 64 bit block ciphers wth SSLv2 only"
          fileout "SWEET32" "LOW" "uses 64 bit block ciphers with SSLv2 only" "$cve" "$cwe" "$hint"
     else
          pr_svrty_best "not vulnerable (OK)";
          if "$using_sockets"; then
               fileout "SWEET32" "OK" "not vulnerable" "$cve" "$cwe"
          else
               if [[ "$nr_supported_ciphers" -ge 38 ]]; then
                    # Likely only PSK/KRB5 ciphers are missing: display discrepancy but no warning
                    if "$HAS_SSL2"; then
                         out ", $nr_supported_ciphers/$nr_sweet32_ciphers (SSLv2: $nr_ssl2_sweet32_ciphers/$nr_ssl2_supported_ciphers) local ciphers"
                         fileout "SWEET32" "OK" "not vulnerable ($nr_supported_ciphers of $nr_sweet32_ciphers (SSLv2: $nr_ssl2_sweet32_ciphers/$nr_ssl2_supported_ciphers)) local ciphers" "$cve" "$cwe"
                    else
                         out ", $nr_supported_ciphers/$nr_sweet32_ciphers local ciphers"
                         fileout "SWEET32" "OK" "not vulnerable ($nr_supported_ciphers of $nr_sweet32_ciphers local ciphers" "$cve" "$cwe"
                    fi
               else
                    if "$HAS_SSL2"; then
                         pr_warning ", $nr_supported_ciphers/$nr_sweet32_ciphers (SSLv2: $nr_ssl2_sweet32_ciphers/$nr_ssl2_supported_ciphers) local ciphers"
                         fileout "SWEET32" "WARN" "not vulnerable but ($nr_supported_ciphers of $nr_sweet32_ciphers (SSLv2: $nr_ssl2_sweet32_ciphers/$nr_ssl2_supported_ciphers)) local ciphers only" "$cve" "$cwe"
                    else
                         pr_warning ", $nr_supported_ciphers/$nr_sweet32_ciphers local ciphers"
                         fileout "SWEET32" "WARN" "not vulnerable but ($nr_supported_ciphers of $nr_sweet32_ciphers) local ciphers only" "$cve" "$cwe"
                    fi
               fi
          fi
     fi
     outln
     tmpfile_handle ${FUNCNAME[0]}.txt
     [[ $sclient_success -ge 6 ]] && return 1
     return 0
}


# Padding Oracle On Downgraded Legacy Encryption, in a nutshell: don't use CBC Ciphers in SSLv3
run_ssl_poodle() {
     local -i sclient_success=0
     local cbc_ciphers="ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:SRP-DSS-AES-256-CBC-SHA:SRP-RSA-AES-256-CBC-SHA:SRP-AES-256-CBC-SHA:DHE-PSK-AES256-CBC-SHA:DHE-RSA-AES256-SHA:DHE-DSS-AES256-SHA:DH-RSA-AES256-SHA:DH-DSS-AES256-SHA:DHE-RSA-CAMELLIA256-SHA:DHE-DSS-CAMELLIA256-SHA:DH-RSA-CAMELLIA256-SHA:DH-DSS-CAMELLIA256-SHA:AECDH-AES256-SHA:ADH-AES256-SHA:ADH-CAMELLIA256-SHA:ECDH-RSA-AES256-SHA:ECDH-ECDSA-AES256-SHA:AES256-SHA:ECDHE-PSK-AES256-CBC-SHA:CAMELLIA256-SHA:RSA-PSK-AES256-CBC-SHA:PSK-AES256-CBC-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:SRP-DSS-AES-128-CBC-SHA:SRP-RSA-AES-128-CBC-SHA:SRP-AES-128-CBC-SHA:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA:DH-RSA-AES128-SHA:DH-DSS-AES128-SHA:DHE-RSA-SEED-SHA:DHE-DSS-SEED-SHA:DH-RSA-SEED-SHA:DH-DSS-SEED-SHA:DHE-RSA-CAMELLIA128-SHA:DHE-DSS-CAMELLIA128-SHA:DH-RSA-CAMELLIA128-SHA:DH-DSS-CAMELLIA128-SHA:AECDH-AES128-SHA:ADH-AES128-SHA:ADH-SEED-SHA:ADH-CAMELLIA128-SHA:ECDH-RSA-AES128-SHA:ECDH-ECDSA-AES128-SHA:AES128-SHA:ECDHE-PSK-AES128-CBC-SHA:DHE-PSK-AES128-CBC-SHA:SEED-SHA:CAMELLIA128-SHA:IDEA-CBC-SHA:RSA-PSK-AES128-CBC-SHA:PSK-AES128-CBC-SHA:KRB5-IDEA-CBC-SHA:KRB5-IDEA-CBC-MD5:ECDHE-RSA-DES-CBC3-SHA:ECDHE-ECDSA-DES-CBC3-SHA:SRP-DSS-3DES-EDE-CBC-SHA:SRP-RSA-3DES-EDE-CBC-SHA:SRP-3DES-EDE-CBC-SHA:EDH-RSA-DES-CBC3-SHA:EDH-DSS-DES-CBC3-SHA:DH-RSA-DES-CBC3-SHA:DH-DSS-DES-CBC3-SHA:AECDH-DES-CBC3-SHA:ADH-DES-CBC3-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-ECDSA-DES-CBC3-SHA:DES-CBC3-SHA:RSA-PSK-3DES-EDE-CBC-SHA:PSK-3DES-EDE-CBC-SHA:KRB5-DES-CBC3-SHA:KRB5-DES-CBC3-MD5:ECDHE-PSK-3DES-EDE-CBC-SHA:DHE-PSK-3DES-EDE-CBC-SHA:EXP1024-DHE-DSS-DES-CBC-SHA:EDH-RSA-DES-CBC-SHA:EDH-DSS-DES-CBC-SHA:DH-RSA-DES-CBC-SHA:DH-DSS-DES-CBC-SHA:ADH-DES-CBC-SHA:EXP1024-DES-CBC-SHA:DES-CBC-SHA:KRB5-DES-CBC-SHA:KRB5-DES-CBC-MD5:EXP-EDH-RSA-DES-CBC-SHA:EXP-EDH-DSS-DES-CBC-SHA:EXP-ADH-DES-CBC-SHA:EXP-DES-CBC-SHA:EXP-RC2-CBC-MD5:EXP-KRB5-RC2-CBC-SHA:EXP-KRB5-DES-CBC-SHA:EXP-KRB5-RC2-CBC-MD5:EXP-KRB5-DES-CBC-MD5:EXP-DH-DSS-DES-CBC-SHA:EXP-DH-RSA-DES-CBC-SHA"
     local cbc_ciphers_hex="c0,14, c0,0a, c0,22, c0,21, c0,20, 00,91, 00,39, 00,38, 00,37, 00,36, 00,88, 00,87, 00,86, 00,85, c0,19, 00,3a, 00,89, c0,0f, c0,05, 00,35, c0,36, 00,84, 00,95, 00,8d, c0,13, c0,09, c0,1f, c0,1e, c0,1d, 00,33, 00,32, 00,31, 00,30, 00,9a, 00,99, 00,98, 00,97, 00,45, 00,44, 00,43, 00,42, c0,18, 00,34, 00,9b, 00,46, c0,0e, c0,04, 00,2f, c0,35, 00,90, 00,96, 00,41, 00,07, 00,94, 00,8c, 00,21, 00,25, c0,12, c0,08, c0,1c, c0,1b, c0,1a, 00,16, 00,13, 00,10, 00,0d, c0,17, 00,1b, c0,0d, c0,03, 00,0a, 00,93, 00,8b, 00,1f, 00,23, c0,34, 00,8f, 00,63, 00,15, 00,12, 00,0f, 00,0c, 00,1a, 00,62, 00,09, 00,1e, 00,22, 00,14, 00,11, 00,19, 00,08, 00,06, 00,27, 00,26, 00,2a, 00,29, 00,0b, 00,0e"
     local hint=""
     local -i nr_cbc_ciphers=0
     local using_sockets=true
     local cve="CVE-2014-3566"
     local cwe="CWE-310"
     local jsonID="POODLE_SSL"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for SSLv3 POODLE (Padding Oracle On Downgraded Legacy Encryption) " && outln
     pr_bold " POODLE, SSL"; out " ($cve)               "

     "$SSL_NATIVE" && using_sockets=false
     # The openssl binary distributed has almost everything we need (PSK and KRB5 ciphers are typically missing).
     # Measurements show that there's little impact whether we use sockets or TLS here, so the default is sockets here
     if "$using_sockets"; then
          tls_sockets "00" "$cbc_ciphers_hex, 00,ff"
          sclient_success=$?
     else
          if ! "$HAS_SSL3"; then
               prln_local_problem "Your $OPENSSL doesn't support SSLv3"
               return 1
          fi
          nr_cbc_ciphers=$(count_ciphers $cbc_ciphers)
          nr_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $cbc_ciphers))
          # SNI not needed as SSLv3 has none:
          $OPENSSL s_client -ssl3 $STARTTLS $BUGS -cipher $cbc_ciphers -connect $NODEIP:$PORT $PROXY >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
          [[ "$DEBUG" -eq 2 ]] && grep -Eq "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
     fi
     if [[ $sclient_success -eq 0 ]]; then
          POODLE=0
          pr_svrty_high "VULNERABLE (NOT ok)"; out ", uses SSLv3+CBC (check TLS_FALLBACK_SCSV mitigation below)"
          fileout "$jsonID" "HIGH" "VULNERABLE, uses SSLv3+CBC" "$cve" "$cwe" "$hint"
     else
          POODLE=1
          pr_svrty_best "not vulnerable (OK)";
          if "$using_sockets"; then
               fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
          else
               if [[ "$nr_supported_ciphers" -ge 83 ]]; then
                    # Likely only KRB and PSK cipher are missing: display discrepancy but no warning
                    out ", $nr_supported_ciphers/$nr_cbc_ciphers local ciphers"
               else
                    pr_warning ", $nr_supported_ciphers/$nr_cbc_ciphers local ciphers"
               fi
               fileout "$jsonID" "OK" "not vulnerable ($nr_supported_ciphers of $nr_cbc_ciphers local ciphers" "$cve" "$cwe"
          fi
     fi
     outln
     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

# for appliance which use padding, no fallback needed
run_tls_poodle() {
     local cve="CVE-2014-8730"
     local cwe="CWE-310"
     local jsonID="POODLE_TLS"

     pr_bold " POODLE, TLS"; out " ($cve), experimental "
     #FIXME
     prln_warning "#FIXME"
     fileout "$jsonID" "WARN" "Not yet implemented #FIXME" "$cve" "$cwe"
     return 0
}

#FIXME: fileout needs to be patched according to new scheme. Postponed as otherwise merge fails ??
#
# This isn't a vulnerability check per se, but checks for the existence of
# the countermeasure to protect against protocol downgrade attacks.
#
run_tls_fallback_scsv() {
     local -i ret=0
     local high_proto="" low_proto=""
     local p high_proto_str protos_to_try
     local jsonID="fallback_SCSV"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for TLS_FALLBACK_SCSV Protection " && outln
     pr_bold " TLS_FALLBACK_SCSV"; out " (RFC 7507)              "

     # First check we have support for TLS_FALLBACK_SCSV in our local OpenSSL
     if ! "$HAS_FALLBACK_SCSV"; then
          prln_local_problem "$OPENSSL lacks TLS_FALLBACK_SCSV support"
          fileout "$jsonID" "WARN" "$OPENSSL lacks TLS_FALLBACK_SCSV support"
          return 1
     fi

     # First determine the highest protocol that the server supports (not including TLSv1.3).
     if [[ "$OPTIMAL_PROTO" == -ssl2 ]]; then
          prln_svrty_critical "No fallback possible, SSLv2 is the only protocol"
          fileout "$jsonID" "CRITICAL" "SSLv2 is the only protocol"
          return 0
     fi
     for p in tls1_2 tls1_1 tls1 ssl3; do
          [[ $(has_server_protocol "$p") -eq 1 ]] && continue
          if [[ $(has_server_protocol "$p") -eq 0 ]]; then
                high_proto="$p"
                break
          fi
          $OPENSSL s_client $(s_client_options "-$p $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          if sclient_connect_successful $? $TMPFILE; then
               high_proto="$p"
               break
          fi
     done
     case "$high_proto" in
          "tls1_2")
               high_proto_str="TLS 1.2"
               protos_to_try="tls1_1 tls1 ssl3" ;;
          "tls1_1")
               high_proto_str="TLS 1.1"
               protos_to_try="tls1 ssl3" ;;
          "tls1")
               high_proto_str="TLS 1"
               protos_to_try="ssl3" ;;
          "ssl3")
               prln_svrty_high "No fallback possible, SSLv3 is the only protocol"
               fileout "$jsonID" "HIGH" "only SSLv3 supported"
               return 0
               ;;
          *)   prln_svrty_good "No fallback possible, TLS 1.3 is the only protocol (OK)"
               fileout "$jsonID" "OK" "only TLS 1.3 supported"
               return 0
     esac

     # Next find a second protocol that the server supports.
     for p in $protos_to_try; do
          [[ $(has_server_protocol "$p") -eq 1 ]] && continue
          if [[ $(has_server_protocol "$p") -eq 0 ]]; then
               low_proto="$p"
               break
          fi
          $OPENSSL s_client $(s_client_options "-$p $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          if sclient_connect_successful $? $TMPFILE; then
               low_proto="$p"
               break
          fi
     done

     if [[ -z "$low_proto" ]]; then
          case "$high_proto" in
               "tls1_2")
                    prln_svrty_good "No fallback possible, no protocol below $high_proto_str offered (OK)"
                    ;;
               *)   outln "No fallback possible, no protocol below $high_proto_str offered (OK)"
                    ;;
          esac
          fileout "$jsonID" "OK" "no protocol below $high_proto_str offered"
          return 0
     fi
     case "$low_proto" in
          "tls1_1")
               p="-no_tls1_2" ;;
          "tls1")
               p="-no_tls1_2 -no_tls1_1" ;;
          "ssl3")
               p="-no_tls1_2 -no_tls1_1 -no_tls1" ;;
     esac
     "$HAS_TLS13" && p+=" -no_tls1_3"
     debugme echo "Simulating fallback from $high_proto to $low_proto"

     # ...and do the test (we need to parse the error here!)
     $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI $p -fallback_scsv") &>$TMPFILE </dev/null
     if grep -q "CONNECTED(00" "$TMPFILE"; then
          if grep -qa "BEGIN CERTIFICATE" "$TMPFILE"; then
               if [[ -z "$POODLE" ]]; then
                    pr_warning "Rerun including POODLE SSL check. "
                    pr_svrty_medium "Downgrade attack prevention NOT supported"
                    fileout "$jsonID" "WARN" "NOT supported. Pls rerun wity POODLE SSL check"
                    ret=1
               elif [[ "$POODLE" -eq 0 ]]; then
                    pr_svrty_high "Downgrade attack prevention NOT supported and vulnerable to POODLE SSL"
                    fileout "$jsonID" "HIGH" "NOT supported and vulnerable to POODLE SSL"
               else
                    pr_svrty_medium "Downgrade attack prevention NOT supported"
                    fileout "$jsonID" "MEDIUM" "NOT supported"
               fi
          elif grep -qa "alert inappropriate fallback" "$TMPFILE"; then
               pr_svrty_good "Downgrade attack prevention supported (OK)"
               fileout "$jsonID" "OK" "supported"
          elif grep -qa "alert handshake failure" "$TMPFILE"; then
               pr_svrty_good "Probably OK. "
               fileout "$jsonID" "OK" "Probably oK"
               # see RFC 7507, https://github.com/drwetter/testssl.sh/issues/121
               # other case reported by Nicolas was F5 and at costumer of mine: the same
               pr_svrty_medium "But received non-RFC-compliant \"handshake failure\" instead of \"inappropriate fallback\""
               fileout "$jsonID" "MEDIUM" "received non-RFC-compliant \"handshake failure\" instead of \"inappropriate fallback\""
          elif grep -qa "ssl handshake failure" "$TMPFILE"; then
               pr_svrty_medium "some unexpected \"handshake failure\" instead of \"inappropriate fallback\""
               fileout "$jsonID" "MEDIUM" "some unexpected \"handshake failure\" instead of \"inappropriate fallback\" (likely: warning)"
          else
               pr_warning "Check failed, unexpected result "
               out ", run $PROG_NAME -Z --debug=1 and look at $TEMPDIR/*tls_fallback_scsv.txt"
               fileout "$jsonID" "WARN" "Check failed, unexpected result, run $PROG_NAME -Z --debug=1 and look at $TEMPDIR/*tls_fallback_scsv.txt"
               ret=1
          fi
     else
          pr_warning "test failed (couldn't connect)"
          fileout "$jsonID" "WARN" "Check failed. (couldn't connect)"
          ret=1
     fi

     outln
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}


# Factoring RSA Export Keys: don't use EXPORT RSA ciphers, see https://freakattack.com/
run_freak() {
     local -i sclient_success=0
     local -i i nr_supported_ciphers=0 len
     # with correct build it should list these 9 ciphers (plus the two latter as SSLv2 ciphers):
     local exportrsa_cipher_list="EXP1024-DES-CBC-SHA:EXP1024-RC2-CBC-MD5:EXP1024-RC4-SHA:EXP1024-RC4-MD5:EXP-EDH-RSA-DES-CBC-SHA:EXP-DH-RSA-DES-CBC-SHA:EXP-DES-CBC-SHA:EXP-RC2-CBC-MD5:EXP-RC4-MD5"
     local exportrsa_tls_cipher_list_hex="00,62, 00,61, 00,64, 00,60, 00,14, 00,0E, 00,08, 00,06, 00,03"
     local exportrsa_ssl2_cipher_list_hex="04,00,80, 02,00,80, 00,00,00"
     local detected_ssl2_ciphers
     local addtl_warning="" hexc
     local using_sockets=true
     local cve="CVE-2015-0204"
     local cwe="CWE-310"
     local hint=""
     local jsonID="FREAK"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for FREAK attack " && outln
     pr_bold " FREAK"; out " ($cve)                     "

     "$SSL_NATIVE" && using_sockets=false
     if "$using_sockets"; then
          nr_supported_ciphers=$(count_words "$exportrsa_tls_cipher_list_hex")+$(count_words "$exportrsa_ssl2_cipher_list_hex")
     else
          nr_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $exportrsa_cipher_list))
     fi
     #echo "========= ${PIPESTATUS[*]}

     case $nr_supported_ciphers in
          0)   prln_local_problem "$OPENSSL doesn't have any EXPORT RSA ciphers configured"
               fileout "$jsonID" "WARN" "Not tested. $OPENSSL doesn't have any EXPORT RSA ciphers configured" "$cve" "$cwe"
               return 0
               ;;
          1|2|3)
               addtl_warning=" ($magenta""tested only with $nr_supported_ciphers out of 9 ciphers only!$off)" ;;
          4|5|6|7)
               addtl_warning=" (tested with $nr_supported_ciphers/9 ciphers)" ;;
          8|9|10|11)
               addtl_warning="" ;;
     esac
     if "$using_sockets"; then
          tls_sockets "03" "$exportrsa_tls_cipher_list_hex, 00,ff"
          sclient_success=$?
          [[ $sclient_success -eq 2 ]] && sclient_success=0
          if [[ $sclient_success -ne 0 ]]; then
               sslv2_sockets "$exportrsa_ssl2_cipher_list_hex" "true"
               if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
                    exportrsa_ssl2_cipher_list_hex="$(strip_spaces "${exportrsa_ssl2_cipher_list_hex//,/}")"
                    len=${#exportrsa_ssl2_cipher_list_hex}
                    detected_ssl2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
                    for (( i=0; i<len; i=i+6 )); do
                         [[ "$detected_ssl2_ciphers" =~ x${exportrsa_ssl2_cipher_list_hex:i:6} ]] && sclient_success=0 && break
                    done
               fi
          fi
     else
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -cipher $exportrsa_cipher_list -connect $NODEIP:$PORT $PROXY $SNI -no_ssl2") >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
          debugme grep -Ea "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
          if [[ $sclient_success -ne 0 ]] && "$HAS_SSL2"; then
               $OPENSSL s_client $STARTTLS $BUGS -cipher $exportrsa_cipher_list -connect $NODEIP:$PORT $PROXY -ssl2 >$TMPFILE 2>$ERRFILE </dev/null
               sclient_connect_successful $? $TMPFILE
               sclient_success=$?
          fi
     fi
     if [[ $sclient_success -eq 0 ]]; then
          pr_svrty_critical "VULNERABLE (NOT ok)"; out ", uses EXPORT RSA ciphers"
          fileout "$jsonID" "CRITICAL" "VULNERABLE, uses EXPORT RSA ciphers" "$cve" "$cwe" "$hint"
     else
          pr_svrty_best "not vulnerable (OK)"; out "$addtl_warning"
          fileout "$jsonID" "OK" "not vulnerable $addtl_warning" "$cve" "$cwe"
     fi
     outln

     if [[ $DEBUG -ge 2 ]]; then
          if "$using_sockets"; then
               for hexc in $(sed 's/, / /g' <<< "$exportrsa_tls_cipher_list_hex, $exportrsa_ssl2_cipher_list_hex"); do
                    if [[ ${#hexc} -eq 5 ]]; then
                         hexc="0x${hexc:0:2},0x${hexc:3:2}"
                    else
                         hexc="0x${hexc:0:2},0x${hexc:3:2},0x${hexc:6:2}"
                    fi
                    for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
                         [[ "$hexc" == "${TLS_CIPHER_HEXCODE[i]}" ]] && break
                    done
                    [[ $i -eq $TLS_NR_CIPHERS ]] && tm_out "$hexc " || tm_out "${TLS_CIPHER_OSSL_NAME[i]} "
               done
               tmln_out
          else
               actually_supported_ciphers $exportrsa_cipher_list
          fi
     fi
     debugme echo $nr_supported_ciphers

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}

# ARGs see below
# Sets the global DH_GROUP_OFFERED, start value: "", after this function:
#    DH_GROUP_OFFERED=""
#    DH_GROUP_OFFERED="<name of group>"
#    return:  1: common primes file problem, 0: went w/o error
get_common_prime() {
     local jsonID2="$1"
     local key_bitstring="$2"
     local spaces="$3"
     local dh_p=""
     local -i subret=0
     local common_primes_file="$TESTSSL_INSTALL_DIR/etc/common-primes.txt"
     local -i lineno_matched=0

     dh_p="$($OPENSSL pkey -pubin -text -noout 2>>$ERRFILE <<< "$key_bitstring" | awk '/prime:/,/generator:/' | grep -Ev "prime|generator")"
     dh_p="$(strip_spaces "$(colon_to_spaces "$(newline_to_spaces "$dh_p")")")"
     [[ "${dh_p:0:2}" == "00" ]] && dh_p="${dh_p:2}"
     DH_GROUP_LEN_P="$((4*${#dh_p}))"
     debugme tmln_out "len(dh_p): $DH_GROUP_LEN_P  |  dh_p: $dh_p"
     [[ "$DEBUG" -gt 1 ]] && echo "$dh_p" > $TEMPDIR/dh_p.txt
     if [[ ! -s "$common_primes_file" ]]; then
          prln_local_problem "couldn't read common primes file $common_primes_file"
          out "${spaces}"
          fileout "$jsonID2" "WARN" "couldn't read common primes file $common_primes_file"
          return 1
     else
          dh_p="$(toupper "$dh_p")"
          # In the previous line of the match is bascially the hint we want to echo
          # the most elegant thing to get the previous line [ awk '/regex/ { print x }; { x=$0 }' ] doesn't work with gawk
          lineno_matched=$(grep -n "$dh_p" "$common_primes_file" 2>/dev/null | awk -F':' '{ print $1 }')
          if [[ "$lineno_matched" -ne 0 ]]; then
               DH_GROUP_OFFERED="$(awk "NR == $lineno_matched-1" "$common_primes_file" | awk -F'"' '{ print $2 }')"
               #subret=1     # vulnerable: common prime
          else
               DH_GROUP_OFFERED="Unknown DH group"
               :
               #subret=0     # not vulnerable: no known common prime
          fi
          return 0
     fi
}


# helper function for run_logjam see below
#
out_common_prime() {
     local jsonID2="$1"
     local cve="$2"
     local cwe="$3"

     [[ "$DH_GROUP_OFFERED" == ffdhe* ]] && [[ ! "$DH_GROUP_OFFERED" =~ \  ]] && DH_GROUP_OFFERED="RFC7919/$DH_GROUP_OFFERED"
     if [[ "$DH_GROUP_OFFERED" =~ ffdhe ]] && [[ "$DH_GROUP_OFFERED" =~ \  ]]; then
          out "common primes detected: "; pr_italic "$DH_GROUP_OFFERED"
          fileout "$jsonID2" "INFO" "$DH_GROUP_OFFERED" "$cve" "$cwe"
     # Now (below) size matters -- i.e. the bit size. As this is about a known prime we label it more strict.
     # This needs maybe needs another thought as it could appear inconsistent with run_pfs and elsewhere.
     # for now we label the bit size similar in the screen, but distinguish the leading text for logjam before
     elif [[ $DH_GROUP_LEN_P -le 800 ]]; then
          pr_svrty_critical "VULNERABLE (NOT ok):"; out " common prime: "
          fileout "$jsonID2" "CRITICAL" "$DH_GROUP_OFFERED" "$cve" "$cwe"
          pr_dh "$DH_GROUP_OFFERED" $DH_GROUP_LEN_P
     elif [[ $DH_GROUP_LEN_P -le 1024 ]]; then
          # really? Here we assume that 1024-bit common prime for nation states are worth and possible to precompute (TBC)
          # otherwise 1024 are just medium
          pr_svrty_high "VULNERABLE (NOT ok):"; out " common prime: "
          fileout "$jsonID2" "HIGH" "$DH_GROUP_OFFERED" "$cve" "$cwe"
          pr_dh "$DH_GROUP_OFFERED" $DH_GROUP_LEN_P
     elif [[ $DH_GROUP_LEN_P -le 1536 ]]; then
          pr_svrty_low "common prime: "
          fileout "$jsonID2" "LOW" "$DH_GROUP_OFFERED" "$cve" "$cwe"
          pr_dh "$DH_GROUP_OFFERED" $DH_GROUP_LEN_P
     else
          out "common prime with $DH_GROUP_LEN_P bits detected: "
          fileout "$jsonID2" "INFO" "$DH_GROUP_OFFERED" "$cve" "$cwe"
          pr_dh "$DH_GROUP_OFFERED" $DH_GROUP_LEN_P
     fi
}


# see https://weakdh.org/logjam.html
run_logjam() {
     local -i sclient_success=0
     local exportdh_cipher_list="EXP1024-DHE-DSS-DES-CBC-SHA:EXP1024-DHE-DSS-RC4-SHA:EXP-EDH-RSA-DES-CBC-SHA:EXP-EDH-DSS-DES-CBC-SHA"
     local exportdh_cipher_list_hex="00,63, 00,65, 00,14, 00,11"
     local all_dh_ciphers="cc,15, 00,b3, 00,91, c0,97, 00,a3, 00,9f, cc,aa, c0,a3, c0,9f, 00,6b, 00,6a, 00,39, 00,38, 00,c4, 00,c3, 00,88, 00,87, 00,a7, 00,6d, 00,3a, 00,c5, 00,89, 00,ab, cc,ad, c0,a7, c0,43, c0,45, c0,47, c0,53, c0,57, c0,5b, c0,67, c0,6d, c0,7d, c0,81, c0,85, c0,91, 00,a2, 00,9e, c0,a2, c0,9e, 00,aa, c0,a6, 00,67, 00,40, 00,33, 00,32, 00,be, 00,bd, 00,9a, 00,99, 00,45, 00,44, 00,a6, 00,6c, 00,34, 00,bf, 00,9b, 00,46, 00,b2, 00,90, c0,96, c0,42, c0,44, c0,46, c0,52, c0,56, c0,5a, c0,66, c0,6c, c0,7c, c0,80, c0,84, c0,90, 00,66, 00,18, 00,8e, 00,16, 00,13, 00,1b, 00,8f, 00,63, 00,15, 00,12, 00,1a, 00,65, 00,14, 00,11, 00,19, 00,17, 00,b5, 00,b4, 00,2d" # 93 ciphers
     local -i i nr_supported_ciphers=0 server_key_exchange_len=0 ephemeral_pub_len=0
     local addtl_warning="" hexc
     local -i ret=0 subret=0
     local server_key_exchange key_bitstring=""
     local spaces="                                           "
     local vuln_exportdh_ciphers=false
     local openssl_no_expdhciphers=false
     local str=""
     local using_sockets=true
     local cve="CVE-2015-4000"
     local cwe="CWE-310"
     local hint=""
     local jsonID="LOGJAM"
     local jsonID2="${jsonID}-common_primes"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for LOGJAM vulnerability " && outln
     pr_bold " LOGJAM"; out " ($cve), experimental      "

     "$SSL_NATIVE" && using_sockets=false
     # Also as the openssl binary distributed has everything we need measurements show that
     # there's no impact whether we use sockets or TLS here, so the default is sockets here
     if ! "$using_sockets"; then
          nr_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $exportdh_cipher_list))
          debugme echo $nr_supported_ciphers
          case $nr_supported_ciphers in
               0)   prln_local_problem "$OPENSSL doesn't have any DH EXPORT ciphers configured"
                    fileout "$jsonID" "WARN" "Not tested. $OPENSSL doesn't support any DH EXPORT ciphers" "$cve" "$cwe"
                    out "$spaces"
                    openssl_no_expdhciphers=true
                    ;;
               1|2|3) addtl_warning=" ($magenta""tested w/ $nr_supported_ciphers/4 ciphers only!$off)" ;;
               4)   ;;
          esac
     fi

     # test for DH export ciphers first
     if "$using_sockets"; then
          tls_sockets "03" "$exportdh_cipher_list_hex, 00,ff"
          sclient_success=$?
          [[ $sclient_success -eq 2 ]] && sclient_success=0
     elif [[ $nr_supported_ciphers -ne 0 ]]; then
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -cipher $exportdh_cipher_list -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
          debugme grep -Ea "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
     fi
     [[ $sclient_success -eq 0 ]] && \
          vuln_exportdh_ciphers=true || \
          vuln_exportdh_ciphers=false

     if [[ $DEBUG -ge 2 ]]; then
          if "$using_sockets"; then
               for hexc in $(sed 's/, / /g' <<< "$exportdh_cipher_list_hex"); do
                    hexc="0x${hexc:0:2},0x${hexc:3:2}"
                    for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
                         [[ "$hexc" == "${TLS_CIPHER_HEXCODE[i]}" ]] && break
                    done
                    [[ $i -eq $TLS_NR_CIPHERS ]] && tm_out "$hexc " || tm_out "${TLS_CIPHER_OSSL_NAME[i]} "
               done
               tmln_out
          else
               echo $(actually_supported_ciphers $exportdh_cipher_list)
          fi
     fi

     # Try all ciphers that use an ephemeral DH key. If successful, check whether the key uses a weak prime.
     if [[ -n "$DH_GROUP_OFFERED" ]]; then
          if [[ "$DH_GROUP_OFFERED" =~ Unknown ]]; then
               subret=0                 # no common DH key detected
          else
               subret=1                 # known prime/DH key
          fi
     elif "$using_sockets"; then
          tls_sockets "03" "$all_dh_ciphers, 00,ff" "ephemeralkey"
          sclient_success=$?
          if [[ $sclient_success -eq 0 ]] || [[ $sclient_success -eq 2 ]]; then
               cp "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" $TMPFILE
               key_bitstring="$(awk '/-----BEGIN PUBLIC KEY/,/-----END PUBLIC KEY/ { print $0 }' $TMPFILE)"
          fi
     else
          # FIXME: determine # of ciphers supported, 48 only are the shipped binaries
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -cipher kEDH -msg -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          if [[ $? -eq 0 ]] && grep -q ServerKeyExchange $TMPFILE; then
               # Example: '<<< TLS 1.0 Handshake [length 010b], ServerKeyExchange'
               # get line with ServerKeyExchange, cut from the beginning to "length ". cut from the end to ']'
               str="$(awk '/<<< TLS 1.[0-2].*ServerKeyExchange$/' $TMPFILE)"
               if [[ -z "$str" ]] ; then
                    str="$(awk '/<<< SSL [2-3].*ServerKeyExchange$/' $TMPFILE)"
               fi
               str="${str#<*length }"
               str="${str%]*}"
               server_key_exchange_len=$(hex2dec "$str")
               server_key_exchange_len=2+$server_key_exchange_len/16
               server_key_exchange="$(grep -A $server_key_exchange_len ServerKeyExchange $TMPFILE | tail -n +2)"
               server_key_exchange="$(toupper "$(strip_spaces "$(newline_to_spaces "$server_key_exchange")")")"
               server_key_exchange="${server_key_exchange%%[!0-9A-F]*}"
               server_key_exchange_len=${#server_key_exchange}
               [[ $server_key_exchange_len -gt 8 ]] && [[ "${server_key_exchange:0:2}" == "0C" ]] && ephemeral_pub_len=$(hex2dec "${server_key_exchange:2:6}")
               [[ $ephemeral_pub_len -ne 0 ]] && [[ $ephemeral_pub_len -le $server_key_exchange_len ]] && key_bitstring="$(get_dh_ephemeralkey "${server_key_exchange:8}")"
          fi
     fi

     if [[ -n "$key_bitstring" ]]; then
          if [[ -z "$DH_GROUP_OFFERED" ]]; then
               get_common_prime "$jsonID2" "$key_bitstring" "$spaces"
               ret=$?                   # no common primes file would be ret=1 --> we should treat that some place else before
          fi
          if [[ "$DH_GROUP_OFFERED" =~ Unknown ]]; then
               subret=0                 # no common DH key detected
          else
               subret=1                 # known prime/DH key
          fi
     elif [[ -z "$DH_GROUP_OFFERED" ]]; then
          subret=3
     fi

     # Now if we have DH export ciphers we print them out first
     if "$vuln_exportdh_ciphers"; then
          pr_svrty_high "VULNERABLE (NOT ok):"; out " uses DH EXPORT ciphers"
          fileout "$jsonID" "HIGH" "VULNERABLE, uses DH EXPORT ciphers" "$cve" "$cwe" "$hint"
          if [[ $subret -eq 3 ]]; then
               out ", no DH key detected with <= TLS 1.2"
               fileout "$jsonID2" "OK" "no DH key detected with <= TLS 1.2"
          elif [[ $subret -eq 1 ]]; then
               out "\n${spaces}"
               out_common_prime "$jsonID2" "$cve" "$cwe"
          elif [[ $subret -eq 0 ]]; then
               out " no common primes detected"
               fileout "$jsonID2" "INFO" "--" "$cve" "$cwe"
          elif [[ $ret -eq 1 ]]; then
               out "FIXME 1"
          fi
     else
          if [[ $subret -eq 1 ]]; then
               out_common_prime "$jsonID2" "$cve" "$cwe"
               if ! "$openssl_no_expdhciphers"; then
                    outln ","
                    out "${spaces}but no DH EXPORT ciphers${addtl_warning}"
                    fileout "$jsonID" "OK" "not vulnerable, no DH EXPORT ciphers,$addtl_warning" "$cve" "$cwe"
               fi
          elif [[ $subret -eq 3 ]]; then
               pr_svrty_good "not vulnerable (OK):"; out " no DH EXPORT ciphers${addtl_warning}"
               fileout "$jsonID" "OK" "not vulnerable, no DH EXPORT ciphers,$addtl_warning" "$cve" "$cwe"
               out ", no DH key detected with <= TLS 1.2"
               fileout "$jsonID2" "OK" "no DH key with <= TLS 1.2" "$cve" "$cwe"
          elif [[ $subret -eq 0 ]]; then
               pr_svrty_good "not vulnerable (OK):"; out " no DH EXPORT ciphers${addtl_warning}"
               fileout "$jsonID" "OK" "not vulnerable, no DH EXPORT ciphers,$addtl_warning" "$cve" "$cwe"
               # we issue a special warning if there's no common prime but the bit length is too low
               if [[ $DH_GROUP_LEN_P -le 1024 ]]; then
                    out "\n${spaces}But: "
                    pr_dh "$DH_GROUP_OFFERED" $DH_GROUP_LEN_P
                    case $? in
                         1) fileout "$jsonID" "CRITICAL" "no DH EXPORT ciphers, no common prime but $DH_GROUP_OFFERED has only $DH_GROUP_LEN_P bits,  $addtl_warning" "$cve" "$cwe" ;;
                         2) fileout "$jsonID" "HIGH" "no DH EXPORT ciphers, no common prime but $DH_GROUP_OFFERED has only $DH_GROUP_LEN_P bits,  $addtl_warning" "$cve" "$cwe";;
                         3) fileout "$jsonID" "MEDIUM" "no DH EXPORT ciphers, no common prime but $DH_GROUP_OFFERED has only $DH_GROUP_LEN_P bits,  $addtl_warning" "$cve" "$cwe";;
                    esac
               else
                    out ", no common prime detected"
                    fileout "$jsonID2" "OK" "--" "$cve" "$cwe"
               fi
          elif [[ $ret -eq 1 ]]; then
               pr_svrty_good "partly not vulnerable:"; out " no DH EXPORT ciphers${addtl_warning}"
               fileout "$jsonID" "OK" "not vulnerable, no DH EXPORT ciphers,$addtl_warning" "$cve" "$cwe"
          fi
     fi

     outln
     tmpfile_handle ${FUNCNAME[0]}.txt
     return $ret
}

# Decrypting RSA with Obsolete and Weakened eNcryption, more @ https://drownattack.com/
run_drown() {
     local -i nr_ciphers_detected ret=0
     local spaces="                                          "
     local cert_fingerprint_sha2=""
     local cve="CVE-2016-0800 CVE-2016-0703"
     local cwe="CWE-310"
     local hint=""
     local jsonID="DROWN"

     if [[ $VULN_COUNT -le $VULN_THRESHLD ]]; then
          outln
          pr_headlineln " Testing for DROWN vulnerability "
          outln
     fi
# if we want to use OPENSSL: check for < openssl 1.0.2g, openssl 1.0.1s if native openssl
     pr_bold " DROWN"; out " (${cve// /, })      "

     # Any fingerprint that is placed in $RSA_CERT_FINGERPRINT_SHA2 is also added to
     # to $CERT_FINGERPRINT_SHA2, so if $CERT_FINGERPRINT_SHA2 is not empty, but
     # $RSA_CERT_FINGERPRINT_SHA2 is empty, then the server doesn't have an RSA certificate.
     if [[ -z "$CERT_FINGERPRINT_SHA2" ]]; then
          get_host_cert "-cipher aRSA"
          [[ $? -eq 0 ]] && cert_fingerprint_sha2="$($OPENSSL x509 -noout -in $HOSTCERT -fingerprint -sha256 2>>$ERRFILE | sed -e 's/^.*Fingerprint=//' -e 's/://g' )"
     else
          cert_fingerprint_sha2="$RSA_CERT_FINGERPRINT_SHA2"
          cert_fingerprint_sha2=${cert_fingerprint_sha2/SHA256 /}
     fi

     if ( [[ "$STARTTLS_PROTOCOL" =~ ldap ]] || [[ "$STARTTLS_PROTOCOL" =~ irc ]] ); then
          prln_local_problem "STARTTLS/$STARTTLS_PROTOCOL and --ssl-native collide here"
          return 1
     fi

     if [[ $(has_server_protocol ssl2) -ne 1 ]]; then
          sslv2_sockets
     else
          [[ aaa == bbb ]]    # provoke retrurn code=1
     fi

     case $? in
          7) # strange reply, couldn't convert the cipher spec length to a hex number
               pr_fixme "strange v2 reply "
               outln " (rerun with DEBUG >=2)"
               [[ $DEBUG -ge 3 ]] && hexdump -C "$TEMPDIR/$NODEIP.sslv2_sockets.dd" | head -1
               fileout "$jsonID" "WARN" "received a strange SSLv2 reply (rerun with DEBUG>=2)" "$cve" "$cwe"
               ret=1
               ;;
          3)   # vulnerable, [[ -n "$cert_fingerprint_sha2" ]] test is not needed as we should have RSA certificate here
               lines=$(count_lines "$(hexdump -C "$TEMPDIR/$NODEIP.sslv2_sockets.dd" 2>/dev/null)")
               debugme tm_out "  ($lines lines)  "
               add_tls_offered ssl2 yes
               if [[ "$lines" -gt 1 ]]; then
                    nr_ciphers_detected=$((V2_HELLO_CIPHERSPEC_LENGTH / 3))
                    if [[ 0 -eq "$nr_ciphers_detected" ]]; then
                         prln_svrty_high "CVE-2015-3197: SSLv2 supported but couldn't detect a cipher (NOT ok)";
                         fileout "$jsonID" "HIGH" "SSLv2 offered, but could not detect a cipher. Make sure you don't use this certificate elsewhere, see https://censys.io/ipv4?q=$cert_fingerprint_sha2" "$cve CVE-2015-3197" "$cwe" "$hint"
                    else
                         prln_svrty_critical  "VULNERABLE (NOT ok), SSLv2 offered with $nr_ciphers_detected ciphers";
                         fileout "$jsonID" "CRITICAL" "VULNERABLE, SSLv2 offered with $nr_ciphers_detected ciphers. Make sure you don't use this certificate elsewhere, see https://censys.io/ipv4?q=$cert_fingerprint_sha2" "$cve" "$cwe" "$hint"
                    fi
                    outln "$spaces Make sure you don't use this certificate elsewhere, see:"
                    out "$spaces "
                    pr_url "https://censys.io/ipv4?q=$cert_fingerprint_sha2"
                    outln
               fi
               ;;
          *)   prln_svrty_best "not vulnerable on this host and port (OK)"
               fileout "$jsonID" "OK" "not vulnerable on this host and port" "$cve" "$cwe"
               if [[ -n "$cert_fingerprint_sha2" ]]; then
                    outln "$spaces make sure you don't use this certificate elsewhere with SSLv2 enabled services"
                    out "$spaces "
                    pr_url "https://censys.io/ipv4?q=$cert_fingerprint_sha2"
                    outln " could help you to find out"
                    fileout "${jsonID}_hint" "INFO" "Make sure you don't use this certificate elsewhere with SSLv2 enabled services, see https://censys.io/ipv4?q=$cert_fingerprint_sha2" "$cve" "$cwe"
               else
                    outln "$spaces no RSA certificate, thus certificate can't be used with SSLv2 elsewhere"
                    fileout "${jsonID}_hint" "INFO" "no RSA certificate, can't be used with SSLv2 elsewhere" "$cve" "$cwe"
               fi
               ;;
     esac

     return $ret
}



# Browser Exploit Against SSL/TLS: don't use CBC Ciphers in SSLv3 TLSv1.0
run_beast(){
     local hexc dash cbc_cipher sslvers auth mac export
     local -a ciph hexcode normalized_hexcode kx enc export2
     local proto proto_hex
     local -i i subret nr_ciphers=0 sclient_success=0
     local detected_cbc_ciphers="" ciphers_to_test
     local higher_proto_supported=""
     local vuln_beast=false
     local spaces="                                           "
     local cr=$'\n'
     local first=true
     local continued=false
     local cbc_cipher_list="EXP-RC2-CBC-MD5:IDEA-CBC-SHA:EXP-DES-CBC-SHA:DES-CBC-SHA:DES-CBC3-SHA:EXP-DH-DSS-DES-CBC-SHA:DH-DSS-DES-CBC-SHA:DH-DSS-DES-CBC3-SHA:EXP-DH-RSA-DES-CBC-SHA:DH-RSA-DES-CBC-SHA:DH-RSA-DES-CBC3-SHA:EXP-EDH-DSS-DES-CBC-SHA:EDH-DSS-DES-CBC-SHA:EDH-DSS-DES-CBC3-SHA:EXP-EDH-RSA-DES-CBC-SHA:EDH-RSA-DES-CBC-SHA:EDH-RSA-DES-CBC3-SHA:EXP-ADH-DES-CBC-SHA:ADH-DES-CBC-SHA:ADH-DES-CBC3-SHA:KRB5-DES-CBC-SHA:KRB5-DES-CBC3-SHA:KRB5-IDEA-CBC-SHA:KRB5-DES-CBC-MD5:KRB5-DES-CBC3-MD5:KRB5-IDEA-CBC-MD5:EXP-KRB5-DES-CBC-SHA:EXP-KRB5-RC2-CBC-SHA:EXP-KRB5-DES-CBC-MD5:EXP-KRB5-RC2-CBC-MD5:AES128-SHA:DH-DSS-AES128-SHA:DH-RSA-AES128-SHA:DHE-DSS-AES128-SHA:DHE-RSA-AES128-SHA:ADH-AES128-SHA:AES256-SHA:DH-DSS-AES256-SHA:DH-RSA-AES256-SHA:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:ADH-AES256-SHA:CAMELLIA128-SHA:DH-DSS-CAMELLIA128-SHA:DH-RSA-CAMELLIA128-SHA:DHE-DSS-CAMELLIA128-SHA:DHE-RSA-CAMELLIA128-SHA:ADH-CAMELLIA128-SHA:EXP1024-RC2-CBC-MD5:EXP1024-DES-CBC-SHA:EXP1024-DHE-DSS-DES-CBC-SHA:CAMELLIA256-SHA:DH-DSS-CAMELLIA256-SHA:DH-RSA-CAMELLIA256-SHA:DHE-DSS-CAMELLIA256-SHA:DHE-RSA-CAMELLIA256-SHA:ADH-CAMELLIA256-SHA:PSK-3DES-EDE-CBC-SHA:PSK-AES128-CBC-SHA:PSK-AES256-CBC-SHA:DHE-PSK-3DES-EDE-CBC-SHA:DHE-PSK-AES128-CBC-SHA:DHE-PSK-AES256-CBC-SHA:RSA-PSK-3DES-EDE-CBC-SHA:RSA-PSK-AES128-CBC-SHA:RSA-PSK-AES256-CBC-SHA:SEED-SHA:DH-DSS-SEED-SHA:DH-RSA-SEED-SHA:DHE-DSS-SEED-SHA:DHE-RSA-SEED-SHA:ADH-SEED-SHA:PSK-AES128-CBC-SHA256:PSK-AES256-CBC-SHA384:DHE-PSK-AES128-CBC-SHA256:DHE-PSK-AES256-CBC-SHA384:RSA-PSK-AES128-CBC-SHA256:RSA-PSK-AES256-CBC-SHA384:ECDH-ECDSA-DES-CBC3-SHA:ECDH-ECDSA-AES128-SHA:ECDH-ECDSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-RSA-AES128-SHA:ECDH-RSA-AES256-SHA:ECDHE-RSA-DES-CBC3-SHA:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AECDH-DES-CBC3-SHA:AECDH-AES128-SHA:AECDH-AES256-SHA:SRP-3DES-EDE-CBC-SHA:SRP-RSA-3DES-EDE-CBC-SHA:SRP-DSS-3DES-EDE-CBC-SHA:SRP-AES-128-CBC-SHA:SRP-RSA-AES-128-CBC-SHA:SRP-DSS-AES-128-CBC-SHA:SRP-AES-256-CBC-SHA:SRP-RSA-AES-256-CBC-SHA:SRP-DSS-AES-256-CBC-SHA:ECDHE-PSK-3DES-EDE-CBC-SHA:ECDHE-PSK-AES128-CBC-SHA:ECDHE-PSK-AES256-CBC-SHA:ECDHE-PSK-AES128-CBC-SHA256:ECDHE-PSK-AES256-CBC-SHA384:PSK-CAMELLIA128-SHA256:PSK-CAMELLIA256-SHA384:DHE-PSK-CAMELLIA128-SHA256:DHE-PSK-CAMELLIA256-SHA384:RSA-PSK-CAMELLIA128-SHA256:RSA-PSK-CAMELLIA256-SHA384:ECDHE-PSK-CAMELLIA128-SHA256:ECDHE-PSK-CAMELLIA256-SHA384"
     local cbc_ciphers_hex="00,06, 00,07, 00,08, 00,09, 00,0A, 00,0B, 00,0C, 00,0D, 00,0E, 00,0F, 00,10, 00,11, 00,12, 00,13, 00,14, 00,15, 00,16, 00,19, 00,1A, 00,1B, 00,1E, 00,1F, 00,21, 00,22, 00,23, 00,25, 00,26, 00,27, 00,29, 00,2A, 00,2F, 00,30, 00,31, 00,32, 00,33, 00,34, 00,35, 00,36, 00,37, 00,38, 00,39, 00,3A, 00,41, 00,42, 00,43, 00,44, 00,45, 00,46, 00,61, 00,62, 00,63, 00,84, 00,85, 00,86, 00,87, 00,88, 00,89, 00,8B, 00,8C, 00,8D, 00,8F, 00,90, 00,91, 00,93, 00,94, 00,95, 00,96, 00,97, 00,98, 00,99, 00,9A, 00,9B, 00,AE, 00,AF, 00,B2, 00,B3, 00,B6, 00,B7, C0,03, C0,04, C0,05, C0,08, C0,09, C0,0A, C0,0D, C0,0E, C0,0F, C0,12, C0,13, C0,14, C0,17, C0,18, C0,19, C0,1A, C0,1B, C0,1C, C0,1D, C0,1E, C0,1F, C0,21, C0,22, C0,34, C0,35, C0,36, C0,37, C0,38, C0,64, C0,65, C0,66, C0,67, C0,68, C0,69, C0,70, C0,71, C0,94, C0,95, C0,96, C0,97, C0,98, C0,99, C0,9A, C0,9B, FE,FE, FE,FF, FF,E0, FF,E1"
     local has_dh_bits="$HAS_DH_BITS"
     local using_sockets=true
     local cve="CVE-2011-3389"
     local cwe="CWE-20"
     local hint=""
     local jsonID="BEAST"

     "$SSL_NATIVE" && using_sockets=false
     if [[ $VULN_COUNT -le $VULN_THRESHLD ]]; then
          outln
          pr_headlineln " Testing for BEAST vulnerability "
          outln
     fi
     pr_bold " BEAST"; out " ($cve)                     "

     # $cbc_ciphers_hex has 126 ciphers, we omitted SRP-AES-256-CBC-SHA bc the trailing 00,ff below will pose
     # a problem for ACE loadbalancers otherwise. So in case we know this is  not true, we'll re-add it
     ! "$SERVER_SIZE_LIMIT_BUG" & "$using_sockets" && cbc_ciphers_hex="$cbc_ciphers_hex, C0,20"

     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false
     if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               hexc="${TLS_CIPHER_HEXCODE[i]}"
               if [[ ${#hexc} -eq 9 ]] && [[ "${TLS_CIPHER_RFC_NAME[i]}" =~ CBC ]] && \
                  [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA256 ]] && [[ ! "${TLS_CIPHER_RFC_NAME[i]}" =~ SHA384 ]]; then
                    ciph[nr_ciphers]="${TLS_CIPHER_OSSL_NAME[i]}"
                    hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2}"
                    rfc_ciph[nr_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                    kx[nr_ciphers]="${TLS_CIPHER_KX[i]}"
                    enc[nr_ciphers]="${TLS_CIPHER_ENC[i]}"
                    export2[nr_ciphers]="${TLS_CIPHER_EXPORT[i]}"
                    ossl_supported[nr_ciphers]=${TLS_CIPHER_OSSL_SUPPORTED[i]}
                    if "$using_sockets" && "$WIDE" && ! "$has_dh_bits" && \
                       ( [[ ${kx[nr_ciphers]} == Kx=ECDH ]] || [[ ${kx[nr_ciphers]} == Kx=DH ]] || [[ ${kx[nr_ciphers]} == Kx=EDH ]] ); then
                         ossl_supported[nr_ciphers]=false
                    fi
                    if [[ "${hexc:2:2}" == 00 ]]; then
                         normalized_hexcode[nr_ciphers]="x${hexc:7:2}"
                    else
                         normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}"
                    fi
                    nr_ciphers+=1
               fi
          done
     else
          while read hexc dash ciph[nr_ciphers] sslvers kx[nr_ciphers] auth enc[nr_ciphers] mac export2[nr_ciphers]; do
               if [[ ":${cbc_cipher_list}:" =~ :${ciph[nr_ciphers]}: ]]; then
                    ossl_supported[nr_ciphers]=true
                    if [[ "${hexc:2:2}" == "00" ]]; then
                         normalized_hexcode[nr_ciphers]="x${hexc:7:2}"
                    else
                         normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}"
                    fi
                    nr_ciphers+=1
               fi
          done  < <(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-tls1 -V")
     fi

     # first determine whether it's mitigated by higher protocols
     for proto in tls1_1 tls1_2; do
          subret=$(has_server_protocol "$proto")
          if [[ $subret -eq 0 ]]; then
               case $proto in
                    tls1_1) higher_proto_supported+=" TLSv1.1" ;;
                    tls1_2) higher_proto_supported+=" TLSv1.2" ;;
               esac
          elif [[ $subret -eq 2 ]]; then
               $OPENSSL s_client $(s_client_options "-state -"${proto}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") 2>>$ERRFILE >$TMPFILE </dev/null
               if sclient_connect_successful $? $TMPFILE; then
                    higher_proto_supported+=" $(get_protocol $TMPFILE)"
                    add_tls_offered "$proto" yes
               fi
          fi
     done

     for proto in ssl3 tls1; do
          if [[ "$proto" == ssl3 ]] && ! "$using_sockets" && ! locally_supported "-${proto}"; then
               continued=true
               out "                                           "
               continue
          fi
          subret=$(has_server_protocol "$proto")
          if [[ $subret -eq 0 ]]; then
               sclient_success=0
          elif [[ $subret -eq 1 ]]; then
               sclient_success=1
          elif [[ "$proto" != "ssl3" ]] || "$HAS_SSL3"; then
               $OPENSSL s_client $(s_client_options "-"$proto" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>>$ERRFILE </dev/null
               sclient_connect_successful $? $TMPFILE
               sclient_success=$?
          else
               tls_sockets "00" "$TLS_CIPHER"
               sclient_success=$?
          fi
          if [[ $sclient_success -ne 0 ]]; then                  # protocol supported?
               if "$continued"; then                             # second round: we hit TLS1
                    if "$HAS_SSL3" || "$using_sockets"; then
                         prln_svrty_good "no SSL3 or TLS1 (OK)"
                         fileout "$jsonID" "OK" "not vulnerable, no SSL3 or TLS1" "$cve" "$cwe"
                    else
                         prln_svrty_good "no TLS1 (OK)"
                         fileout "$jsonID" "OK" "not vulnerable, no TLS1" "$cve" "$cwe"
                    fi
                    return 0
               else                # protocol not succeeded but it's the first time
                    continued=true
                    continue       # protocol not supported, so we do not need to check each cipher with that protocol
               fi
          fi # protocol succeeded
          add_tls_offered "$proto" yes

          # now we test in one shot with the precompiled ciphers
          if "$using_sockets"; then
               case "$proto" in
                    "ssl3") proto_hex="00" ;;
                    "tls1") proto_hex="01" ;;
               esac
               tls_sockets "$proto_hex" "$cbc_ciphers_hex, 00,ff"
               [[ $? -eq 0 ]] || continue
          else
               $OPENSSL s_client $(s_client_options "-"$proto" -cipher "$cbc_cipher_list" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>>$ERRFILE </dev/null
               sclient_connect_successful $? $TMPFILE || continue
          fi

          detected_cbc_ciphers=""
          for ((i=0; i<nr_ciphers; i++)); do
               ciphers_found[i]=false
               sigalg[nr_ciphers]=""
          done
          while true; do
               [[ "$proto" == "ssl3" ]] && ! "$HAS_SSL3" && break
               ciphers_to_test=""
               for (( i=0; i < nr_ciphers; i++ )); do
                    ! "${ciphers_found[i]}" && "${ossl_supported[i]}" && ciphers_to_test+=":${ciph[i]}"
               done
               [[ -z "$ciphers_to_test" ]] && break
               $OPENSSL s_client $(s_client_options "-cipher "${ciphers_to_test:1}" -"${proto}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>>$ERRFILE </dev/null
               sclient_connect_successful $? $TMPFILE || break
               cbc_cipher=$(get_cipher $TMPFILE)
               [[ -z "$cbc_cipher" ]] && break
               for (( i=0; i < nr_ciphers; i++ )); do
                    [[ "$cbc_cipher" == "${ciph[i]}" ]] && break
               done
               ciphers_found[i]=true
               if [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] || [[ "${rfc_ciph[i]}" == - ]]; then
                    detected_cbc_ciphers+="${ciph[i]} "
               else
                    detected_cbc_ciphers+="${rfc_ciph[i]} "
               fi
               vuln_beast=true
               if "$WIDE" && ( [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]] ); then
                    dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                    kx[i]="${kx[i]} $dhlen"
               fi
               "$WIDE" && "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                    sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
          done
          if "$using_sockets"; then
               while true; do
                    ciphers_to_test=""
                    for (( i=0; i < nr_ciphers; i++ )); do
                         ! "${ciphers_found[i]}" && ciphers_to_test+=", ${hexcode[i]}"
                    done
                    [[ -z "$ciphers_to_test" ]] && break
                    if "$SHOW_SIGALGO"; then
                         tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "all"
                    else
                         tls_sockets "$proto_hex" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
                    fi
                    [[ $? -ne 0 ]] && break
                    cbc_cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
                    for (( i=0; i < nr_ciphers; i++ )); do
                         [[ "$cbc_cipher" == "${rfc_ciph[i]}" ]] && break
                    done
                    ciphers_found[i]=true
                    if ( [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ "${ciph[i]}" != - ]] ) || [[ "${rfc_ciph[i]}" == - ]]; then
                         detected_cbc_ciphers+="${ciph[i]} "
                    else
                         detected_cbc_ciphers+="${rfc_ciph[i]} "
                    fi
                    vuln_beast=true
                    if "$WIDE" && ( [[ ${kx[i]} == Kx=ECDH ]] || [[ ${kx[i]} == Kx=DH ]] || [[ ${kx[i]} == Kx=EDH ]] ); then
                         dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                         kx[i]="${kx[i]} $dhlen"
                    fi
                    "$WIDE" && "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && \
                         sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
               done
          fi

          if "$WIDE" && [[ -n "$detected_cbc_ciphers" ]]; then
               out "\n "; pr_underline "$(toupper $proto):\n";
               if "$first"; then
                    neat_header
               fi
               first=false
               for (( i=0; i < nr_ciphers; i++ )); do
                    if "${ciphers_found[i]}" || "$SHOW_EACH_C"; then
                         export="${export2[i]}"
                         neat_list "$(tolower "${normalized_hexcode[i]}")" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
                         if "$SHOW_EACH_C"; then
                              if "${ciphers_found[i]}"; then
                                   if [[ -n "$higher_proto_supported" ]]; then
                                        pr_svrty_low "available"
                                   else
                                        pr_svrty_medium "available"
                                   fi
                              else
                                   pr_deemphasize "not a/v"
                              fi
                         fi
                         outln "${sigalg[i]}"
                    fi
               done
          fi

          if ! "$WIDE"; then
               if [[ -n "$detected_cbc_ciphers" ]]; then
                    fileout "${jsonID}_CBC_$(toupper $proto)" "MEDIUM" "$detected_cbc_ciphers" "$cve" "$cwe" "$hint"
                    ! "$first" && out "$spaces"
                    out "$(toupper $proto): "
                    [[ -n "$higher_proto_supported" ]] && \
                         pr_svrty_low "$(out_row_aligned_max_width "$detected_cbc_ciphers" "                                                 " $TERM_WIDTH)" || \
                         pr_svrty_medium "$(out_row_aligned_max_width "$detected_cbc_ciphers" "                                                 " $TERM_WIDTH)"
                    outln
                    detected_cbc_ciphers=""  # empty for next round
                    first=false
               else
                    [[ $proto == "tls1" ]] && ! $first && echo -n "$spaces "
                    prln_svrty_good "no CBC ciphers for $(toupper $proto) (OK)"
                    first=false
               fi
          else
               if ! "$vuln_beast" ; then
                    prln_svrty_good "no CBC ciphers for $(toupper $proto) (OK)"
                    fileout "${jsonID}_CBC_$(toupper $proto)" "OK" "No CBC ciphers for $(toupper $proto)" "$cve" "$cwe"
               fi
          fi
     done  # for proto in ssl3 tls1

     if "$vuln_beast"; then
          if [[ -n "$higher_proto_supported" ]]; then
               if "$WIDE"; then
                    outln; out " "
                    # NOT ok seems too harsh for me if we have TLS >1.0
                    pr_svrty_low "VULNERABLE"
                    outln " -- but also supports higher protocols (possible mitigation) $higher_proto_supported"
                    outln
               else
                    out "$spaces"
                    pr_svrty_low "VULNERABLE"
                    outln " -- but also supports higher protocols $higher_proto_supported (likely mitigated)"
               fi
               fileout "$jsonID" "LOW" "VULNERABLE -- but also supports higher protocols $higher_proto_supported (likely mitigated)" "$cve" "$cwe" "$hint"
          else
               if "$WIDE"; then
                    outln
               else
                    out "$spaces"
               fi
               pr_svrty_medium "VULNERABLE"
               outln " -- and no higher protocols as mitigation supported"
               fileout "$jsonID" "MEDIUM" "VULNERABLE -- and no higher protocols as mitigation supported" "$cve" "$cwe" "$hint"
          fi
     fi
     "$first" && ! "$vuln_beast" && prln_svrty_good "no CBC ciphers found for any protocol (OK)"

     "$using_sockets" && HAS_DH_BITS="$has_dh_bits"
     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


# http://www.isg.rhul.ac.uk/tls/Lucky13.html
# in a nutshell: don't offer CBC suites (again). MAC as a fix for padding oracles is not enough. Best: TLS v1.2+ AES GCM
run_lucky13() {
     local spaces="                                           "
     local cbc_ciphers="ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:SRP-DSS-AES-256-CBC-SHA:SRP-RSA-AES-256-CBC-SHA:SRP-AES-256-CBC-SHA:RSA-PSK-AES256-CBC-SHA384:DHE-PSK-AES256-CBC-SHA384:DHE-PSK-AES256-CBC-SHA:ECDHE-PSK-CAMELLIA256-SHA384:RSA-PSK-CAMELLIA256-SHA384:DHE-PSK-CAMELLIA256-SHA384:PSK-AES256-CBC-SHA384:PSK-CAMELLIA256-SHA384:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA256:DH-RSA-AES256-SHA256:DH-DSS-AES256-SHA256:DHE-RSA-AES256-SHA:DHE-DSS-AES256-SHA:DH-RSA-AES256-SHA:DH-DSS-AES256-SHA:ECDHE-RSA-CAMELLIA256-SHA384:ECDHE-ECDSA-CAMELLIA256-SHA384:DHE-RSA-CAMELLIA256-SHA256:DHE-DSS-CAMELLIA256-SHA256:DH-RSA-CAMELLIA256-SHA256:DH-DSS-CAMELLIA256-SHA256:DHE-RSA-CAMELLIA256-SHA:DHE-DSS-CAMELLIA256-SHA:DH-RSA-CAMELLIA256-SHA:DH-DSS-CAMELLIA256-SHA:AECDH-AES256-SHA:ADH-AES256-SHA256:ADH-AES256-SHA:ADH-CAMELLIA256-SHA256:ADH-CAMELLIA256-SHA:ECDH-RSA-AES256-SHA384:ECDH-ECDSA-AES256-SHA384:ECDH-RSA-AES256-SHA:ECDH-ECDSA-AES256-SHA:ECDH-RSA-CAMELLIA256-SHA384:ECDH-ECDSA-CAMELLIA256-SHA384:AES256-SHA256:AES256-SHA:CAMELLIA256-SHA256:ECDHE-PSK-AES256-CBC-SHA384:ECDHE-PSK-AES256-CBC-SHA:CAMELLIA256-SHA:RSA-PSK-AES256-CBC-SHA:PSK-AES256-CBC-SHA:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:SRP-DSS-AES-128-CBC-SHA:SRP-RSA-AES-128-CBC-SHA:SRP-AES-128-CBC-SHA:DHE-RSA-AES128-SHA256:DHE-DSS-AES128-SHA256:DH-RSA-AES128-SHA256:DH-DSS-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA:DH-RSA-AES128-SHA:DH-DSS-AES128-SHA:ECDHE-RSA-CAMELLIA128-SHA256:ECDHE-ECDSA-CAMELLIA128-SHA256:DHE-RSA-CAMELLIA128-SHA256:DHE-DSS-CAMELLIA128-SHA256:DH-RSA-CAMELLIA128-SHA256:DH-DSS-CAMELLIA128-SHA256:DHE-RSA-SEED-SHA:DHE-DSS-SEED-SHA:DH-RSA-SEED-SHA:DH-DSS-SEED-SHA:DHE-RSA-CAMELLIA128-SHA:DHE-DSS-CAMELLIA128-SHA:DH-RSA-CAMELLIA128-SHA:DH-DSS-CAMELLIA128-SHA:AECDH-AES128-SHA:ADH-AES128-SHA256:ADH-AES128-SHA:ADH-CAMELLIA128-SHA256:ADH-SEED-SHA:ADH-CAMELLIA128-SHA:ECDH-RSA-AES128-SHA256:ECDH-ECDSA-AES128-SHA256:ECDH-RSA-AES128-SHA:ECDH-ECDSA-AES128-SHA:ECDH-RSA-CAMELLIA128-SHA256:ECDH-ECDSA-CAMELLIA128-SHA256:AES128-SHA256:AES128-SHA:CAMELLIA128-SHA256:ECDHE-PSK-AES128-CBC-SHA256:ECDHE-PSK-AES128-CBC-SHA:RSA-PSK-AES128-CBC-SHA256:DHE-PSK-AES128-CBC-SHA256:DHE-PSK-AES128-CBC-SHA:SEED-SHA:CAMELLIA128-SHA:ECDHE-PSK-CAMELLIA128-SHA256:RSA-PSK-CAMELLIA128-SHA256:DHE-PSK-CAMELLIA128-SHA256:PSK-AES128-CBC-SHA256:PSK-CAMELLIA128-SHA256:IDEA-CBC-SHA:RSA-PSK-AES128-CBC-SHA:PSK-AES128-CBC-SHA:KRB5-IDEA-CBC-SHA:KRB5-IDEA-CBC-MD5:ECDHE-RSA-DES-CBC3-SHA:ECDHE-ECDSA-DES-CBC3-SHA:SRP-DSS-3DES-EDE-CBC-SHA:SRP-RSA-3DES-EDE-CBC-SHA:SRP-3DES-EDE-CBC-SHA:EDH-RSA-DES-CBC3-SHA:EDH-DSS-DES-CBC3-SHA:DH-RSA-DES-CBC3-SHA:DH-DSS-DES-CBC3-SHA:AECDH-DES-CBC3-SHA:ADH-DES-CBC3-SHA:ECDH-RSA-DES-CBC3-SHA:ECDH-ECDSA-DES-CBC3-SHA:DES-CBC3-SHA:RSA-PSK-3DES-EDE-CBC-SHA:PSK-3DES-EDE-CBC-SHA:KRB5-DES-CBC3-SHA:KRB5-DES-CBC3-MD5:ECDHE-PSK-3DES-EDE-CBC-SHA:DHE-PSK-3DES-EDE-CBC-SHA:EXP1024-DHE-DSS-DES-CBC-SHA:EDH-RSA-DES-CBC-SHA:EDH-DSS-DES-CBC-SHA:DH-RSA-DES-CBC-SHA:DH-DSS-DES-CBC-SHA:ADH-DES-CBC-SHA:EXP1024-DES-CBC-SHA:DES-CBC-SHA:KRB5-DES-CBC-SHA:KRB5-DES-CBC-MD5:EXP-EDH-RSA-DES-CBC-SHA:EXP-EDH-DSS-DES-CBC-SHA:EXP-ADH-DES-CBC-SHA:EXP-DES-CBC-SHA:EXP-RC2-CBC-MD5:EXP-KRB5-RC2-CBC-SHA:EXP-KRB5-DES-CBC-SHA:EXP-KRB5-RC2-CBC-MD5:EXP-KRB5-DES-CBC-MD5:EXP-DH-DSS-DES-CBC-SHA:EXP-DH-RSA-DES-CBC-SHA"
     cbc_ciphers_hex1="c0,28, c0,24, c0,14, c0,0a, c0,22, c0,21, c0,20, 00,b7, 00,b3, 00,91, c0,9b, c0,99, c0,97, 00,af, c0,95, 00,6b, 00,6a, 00,69, 00,68, 00,39, 00,38, 00,37, 00,36, c0,77, c0,73, 00,c4, 00,c3, 00,c2, 00,c1, 00,88, 00,87, 00,86, 00,85, c0,19, 00,6d, 00,3a, 00,c5, 00,89, c0,2a, c0,26, c0,0f, c0,05, c0,79, c0,75, 00,3d, 00,35, 00,c0, c0,38, c0,36, 00,84, 00,95, 00,8d, c0,3d, c0,3f, c0,41, c0,43, c0,45, c0,47, c0,49, c0,4b, c0,4d, c0,4f, c0,65, c0,67, c0,69, c0,71, c0,27, c0,23, c0,13, c0,09, c0,1f, c0,1e, c0,1d, 00,67, 00,40, 00,3f, 00,3e, 00,33, 00,32, 00,31, 00,30, c0,76, c0,72, 00,be, 00,bd, 00,bc, 00,bb, 00,9a, 00,99, 00,98, 00,97, 00,45, 00,44, 00,43, 00,42, c0,18, 00,6c, 00,34, 00,bf, 00,9b, 00,46, c0,29, c0,25, c0,0e, c0,04, c0,78, c0,74, 00,3c, 00,2f, 00,ba"
     cbc_ciphers_hex2="c0,37, c0,35, 00,b6, 00,b2, 00,90, 00,96, 00,41, c0,9a, c0,98, c0,96, 00,ae, c0,94, 00,07, 00,94, 00,8c, 00,21, 00,25, c0,3c, c0,3e, c0,40, c0,42, c0,44, c0,46, c0,48, c0,4a, c0,4c, c0,4e, c0,64, c0,66, c0,68, c0,70, c0,12, c0,08, c0,1c, c0,1b, c0,1a, 00,16, 00,13, 00,10, 00,0d, c0,17, 00,1b, c0,0d, c0,03, 00,0a, 00,93, 00,8b, 00,1f, 00,23, c0,34, 00,8f, fe,ff, ff,e0, 00,63, 00,15, 00,12, 00,0f, 00,0c, 00,1a, 00,62, 00,09, 00,61, 00,1e, 00,22, fe,fe, ff,e1, 00,14, 00,11, 00,19, 00,08, 00,06, 00,27, 00,26, 00,2a, 00,29, 00,0b, 00,0e"
     local has_dh_bits="$HAS_DH_BITS"
     local -i nr_supported_ciphers=0 sclient_success
     local using_sockets=true
     local cve="CVE-2013-0169"
     local cwe="CWE-310"
     local hint=""
     local jsonID="LUCKY13"

     if [[ $VULN_COUNT -le $VULN_THRESHLD ]]; then
          outln
          pr_headlineln " Testing for LUCKY13 vulnerability "
          outln
     fi
     pr_bold " LUCKY13"; out " ($cve), experimental     "

     "$SSL_NATIVE" && using_sockets=false
     # The openssl binary distributed has almost everything we need (PSK, KRB5 ciphers and feff, ffe0 are typically missing).
     # Measurements show that there's little impact whether we use sockets or TLS here, so the default is sockets here

     if "$using_sockets"; then
          tls_sockets "03" "${cbc_ciphers_hex1}, 00,ff"
          sclient_success=$?
          [[ "$sclient_success" -eq 2 ]] && sclient_success=0
          if [[ $sclient_success -ne 0 ]]; then
               tls_sockets "03" "${cbc_ciphers_hex2}, 00,ff"
               sclient_success=$?
               [[ $sclient_success -eq 2 ]] && sclient_success=0
          fi
     else
          nr_cbc_ciphers=$(count_ciphers $cbc_ciphers)
          nr_supported_ciphers=$(count_ciphers $(actually_supported_ciphers $cbc_ciphers))
          $OPENSSL s_client $(s_client_options "$STARTTLS $BUGS -no_ssl2 -cipher $cbc_ciphers -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? $TMPFILE
          sclient_success=$?
          [[ "$DEBUG" -eq 2 ]] && grep -Eq "error|failure" $ERRFILE | grep -Eav "unable to get local|verify error"
     fi
     if [[ $sclient_success -eq 0 ]]; then
          out "potentially "
          pr_svrty_low "VULNERABLE"; out ", uses cipher block chaining (CBC) ciphers with TLS. Check patches"
          fileout "$jsonID" "LOW" "potentially vulnerable, uses TLS CBC ciphers" "$cve" "$cwe" "$hint"
          # the CBC padding which led to timing differences during MAC processing has been solved in openssl (https://www.openssl.org/news/secadv/20130205.txt)
          # and other software. However we can't tell with reasonable effort from the outside. Thus we still issue a warning and label it experimental
     else
          pr_svrty_best "not vulnerable (OK)";
          if "$using_sockets"; then
               fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
          else
               if [[ "$nr_supported_ciphers" -ge 133 ]]; then
                    # Likely only PSK/KRB5 ciphers are missing: display discrepancy but no warning
                    out ", $nr_supported_ciphers/$nr_cbc_ciphers local ciphers"
               else
                    pr_warning ", $nr_supported_ciphers/$nr_cbc_ciphers local ciphers"
               fi
               fileout "$jsonID" "OK" "not vulnerable ($nr_supported_ciphers of $nr_cbc_ciphers local ciphers" "$cve" "$cwe"
          fi
     fi
     outln
     tmpfile_handle ${FUNCNAME[0]}.txt
     [[ $sclient_success -ge 6 ]] && return 1
     return 0
}


# https://tools.ietf.org/html/rfc7465    REQUIRES that TLS clients and servers NEVER negotiate the use of RC4 cipher suites!
# https://en.wikipedia.org/wiki/Transport_Layer_Security#RC4_attacks
# http://blog.cryptographyengineering.com/2013/03/attack-of-week-rc4-is-kind-of-broken-in.html
#
run_rc4() {
     local -i rc4_offered=0
     local -i nr_ciphers=0 nr_ossl_ciphers=0 nr_nonossl_ciphers=0 sclient_success=0
     local n auth mac export hexc sslv2_ciphers_hex="" sslv2_ciphers_ossl="" s
     local -a normalized_hexcode hexcode ciph sslvers kx enc export2 sigalg ossl_supported
     local -i i
     local -a ciphers_found ciphers_found2 hexcode2 ciph2 rfc_ciph2
     local -i -a index
     local dhlen available="" ciphers_to_test supported_sslv2_ciphers proto
     local has_dh_bits="$HAS_DH_BITS" rc4_detected=""
     local using_sockets=true
     local cve="CVE-2013-2566 CVE-2015-2808"
     local cwe="CWE-310"
     local hint=""
     local jsonID="RC4"

     "$SSL_NATIVE" && using_sockets=false
     "$FAST" && using_sockets=false
     [[ $TLS_NR_CIPHERS == 0 ]] && using_sockets=false

     if [[ $VULN_COUNT -le $VULN_THRESHLD ]]; then
          outln
          pr_headlineln " Checking for vulnerable RC4 Ciphers "
          outln
     fi
     pr_bold " RC4"; out " (${cve// /, })        "

     # get a list of all the cipher suites to test
     if "$using_sockets" || [[ $OSSL_VER_MAJOR -lt 1 ]]; then
          for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
               if [[ "${TLS_CIPHER_RFC_NAME[i]}" =~ RC4 ]] && ( "$using_sockets" || "${TLS_CIPHER_OSSL_SUPPORTED[i]}" ); then
                    hexc="$(tolower "${TLS_CIPHER_HEXCODE[i]}")"
                    ciph[nr_ciphers]="${TLS_CIPHER_OSSL_NAME[i]}"
                    rfc_ciph[nr_ciphers]="${TLS_CIPHER_RFC_NAME[i]}"
                    sslvers[nr_ciphers]="${TLS_CIPHER_SSLVERS[i]}"
                    kx[nr_ciphers]="${TLS_CIPHER_KX[i]}"
                    enc[nr_ciphers]="${TLS_CIPHER_ENC[i]}"
                    export2[nr_ciphers]="${TLS_CIPHER_EXPORT[i]}"
                    ciphers_found[nr_ciphers]=false
                    sigalg[nr_ciphers]=""
                    ossl_supported[nr_ciphers]="${TLS_CIPHER_OSSL_SUPPORTED[i]}"
                    if "$using_sockets" && "$WIDE" && ! "$HAS_DH_BITS" &&
                       ( [[ ${kx[nr_ciphers]} == "Kx=ECDH" ]] || [[ ${kx[nr_ciphers]} == "Kx=DH" ]] || [[ ${kx[nr_ciphers]} == "Kx=EDH" ]] ); then
                         ossl_supported[nr_ciphers]=false
                    fi
                    if [[ ${#hexc} -eq 9 ]]; then
                         hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2}"
                         if [[ "${hexc:2:2}" == 00 ]]; then
                              normalized_hexcode[nr_ciphers]="x${hexc:7:2}"
                         else
                              normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}"
                         fi
                    else
                         hexcode[nr_ciphers]="${hexc:2:2},${hexc:7:2},${hexc:12:2}"
                         normalized_hexcode[nr_ciphers]="x${hexc:2:2}${hexc:7:2}${hexc:12:2}"
                         sslv2_ciphers_hex+=", ${hexcode[nr_ciphers]}"
                         sslv2_ciphers_ossl+=":${ciph[nr_ciphers]}"
                    fi
                    nr_ciphers+=1
               fi
          done
     else
          while read hexc n ciph[nr_ciphers] sslvers[nr_ciphers] kx[nr_ciphers] auth enc[nr_ciphers] mac export2[nr_ciphers]; do
               if [[ "${ciph[nr_ciphers]}" =~ RC4 ]]; then
                    ciphers_found[nr_ciphers]=false
                    if [[ ${#hexc} -eq 9 ]]; then
                         if [[ "${hexc:2:2}" == 00 ]]; then
                              normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:7:2}")"
                         else
                              normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:2:2}${hexc:7:2}")"
                         fi
                    else
                         normalized_hexcode[nr_ciphers]="$(tolower "x${hexc:2:2}${hexc:7:2}${hexc:12:2}")"
                         sslv2_ciphers_ossl+=":${ciph[nr_ciphers]}"
                    fi
                    sigalg[nr_ciphers]=""
                    ossl_supported[nr_ciphers]=true
                    nr_ciphers+=1
               fi
          done < <($OPENSSL ciphers $OSSL_CIPHERS_S -V 'ALL:COMPLEMENTOFALL:@STRENGTH' 2>>$ERRFILE)
     fi

     if "$using_sockets" && [[ -n "$sslv2_ciphers_hex" ]]; then
          sslv2_sockets "${sslv2_ciphers_hex:2}" "true"
          if [[ $? -eq 3 ]] && [[ "$V2_HELLO_CIPHERSPEC_LENGTH" -ne 0 ]]; then
               supported_sslv2_ciphers="$(grep "Supported cipher: " "$TEMPDIR/$NODEIP.parse_sslv2_serverhello.txt")"
               "$WIDE" && "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$HOSTCERT")"
               for (( i=0 ; i<nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == SSLv2 ]] && [[ "$supported_sslv2_ciphers" =~ ${normalized_hexcode[i]} ]]; then
                         ciphers_found[i]=true
                         "$WIDE" && "$SHOW_SIGALGO" && sigalg[i]="$s"
                         rc4_offered=1
                    fi
               done
          fi
     elif "$HAS_SSL2" && [[ -n "$sslv2_ciphers_ossl" ]]; then
          $OPENSSL s_client -cipher "${sslv2_ciphers_ossl:1}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY -ssl2 >$TMPFILE 2>$ERRFILE </dev/null
          sclient_connect_successful $? "$TMPFILE"
          if [[ $? -eq 0 ]]; then
               supported_sslv2_ciphers="$(grep -A 4 "Ciphers common between both SSL endpoints:" $TMPFILE)"
               "$WIDE" && "$SHOW_SIGALGO" && s="$(read_sigalg_from_file "$TMPFILE")"
               for (( i=0 ; i<nr_ciphers; i++ )); do
                    if [[ "${sslvers[i]}" == SSLv2 ]] && [[ "$supported_sslv2_ciphers" =~ ${ciph[i]} ]]; then
                         ciphers_found[i]=true
                         "$WIDE" && "$SHOW_SIGALGO" && sigalg[i]="$s"
                         rc4_offered=1
                    fi
               done
          fi
     fi

     for (( i=0; i < nr_ciphers; i++ )); do
          if "${ossl_supported[i]}" && [[ "${sslvers[i]}" != SSLv2 ]]; then
               ciphers_found2[nr_ossl_ciphers]=false
               ciph2[nr_ossl_ciphers]="${ciph[i]}"
               index[nr_ossl_ciphers]=$i
               nr_ossl_ciphers+=1
          fi
     done

     for proto in -no_ssl2 -tls1_1 -tls1 -ssl3; do
          [[ "$proto" != -no_ssl2 ]] && [[ $(has_server_protocol "${proto:1}") -eq 1 ]] && continue
          ! "$HAS_SSL3" && [[ "$proto" == -ssl3 ]] && continue
          while true; do
               ciphers_to_test=""
               for (( i=0; i < nr_ossl_ciphers; i++ )); do
                    ! "${ciphers_found2[i]}" && ciphers_to_test+=":${ciph2[i]}"
               done
               [[ -z "$ciphers_to_test" ]] && break
               $OPENSSL s_client $(s_client_options "$proto -cipher "${ciphers_to_test:1}" $STARTTLS $BUGS -connect $NODEIP:$PORT $PROXY $SNI") >$TMPFILE 2>$ERRFILE </dev/null
               sclient_connect_successful $? "$TMPFILE" || break
               cipher=$(get_cipher $TMPFILE)
               [[ -z "$cipher" ]] && break
               for (( i=0; i < nr_ossl_ciphers; i++ )); do
                    [[ "$cipher" == "${ciph2[i]}" ]] && ciphers_found2[i]=true && break
               done
               [[ $i -eq $nr_ossl_ciphers ]] && break
               rc4_offered=1
               i=${index[i]}
               ciphers_found[i]=true
               if "$WIDE" && ( [[ ${kx[i]} == "Kx=ECDH" ]] || [[ ${kx[i]} == "Kx=DH" ]] || [[ ${kx[i]} == "Kx=EDH" ]] ); then
                    dhlen=$(read_dhbits_from_file "$TMPFILE" quiet)
                    kx[i]="${kx[i]} $dhlen"
               fi
               "$WIDE" && "$SHOW_SIGALGO" && grep -q "\-\-\-\-\-BEGIN CERTIFICATE\-\-\-\-\-" $TMPFILE && \
                    sigalg[i]="$(read_sigalg_from_file "$TMPFILE")"
          done
     done

     if "$using_sockets"; then
          for (( i=0; i < nr_ciphers; i++ )); do
               if ! "${ciphers_found[i]}" && [[ "${sslvers[i]}" != SSLv2 ]]; then
                    ciphers_found2[nr_nonossl_ciphers]=false
                    hexcode2[nr_nonossl_ciphers]="${hexcode[i]}"
                    rfc_ciph2[nr_nonossl_ciphers]="${rfc_ciph[i]}"
                    index[nr_nonossl_ciphers]=$i
                    nr_nonossl_ciphers+=1
               fi
          done
     fi

     for proto in 03 02 01 00; do
          [[ $(has_server_protocol "$proto") -eq 1 ]] && continue
          while true; do
               ciphers_to_test=""
               for (( i=0; i < nr_nonossl_ciphers; i++ )); do
                    ! "${ciphers_found2[i]}" && ciphers_to_test+=", ${hexcode2[i]}"
               done
               [[ -z "$ciphers_to_test" ]] && break
               if "$WIDE" && "$SHOW_SIGALGO"; then
                    tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "all"
               else
                    tls_sockets "$proto" "${ciphers_to_test:2}, 00,ff" "ephemeralkey"
               fi
               sclient_success=$?
               [[ $sclient_success -ne 0 ]] && [[ $sclient_success -ne 2 ]] && break
               cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
               for (( i=0; i < nr_nonossl_ciphers; i++ )); do
                    [[ "$cipher" == "${rfc_ciph2[i]}" ]] && ciphers_found2[i]=true && break
               done
               [[ $i -eq $nr_nonossl_ciphers ]] && break
               rc4_offered=1
               i=${index[i]}
               ciphers_found[i]=true
               if "$WIDE" && ( [[ ${kx[i]} == "Kx=ECDH" ]] || [[ ${kx[i]} == "Kx=DH" ]] || [[ ${kx[i]} == "Kx=EDH" ]] ); then
                    dhlen=$(read_dhbits_from_file "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" quiet)
                    kx[i]="${kx[i]} $dhlen"
               fi
               "$WIDE" && "$SHOW_SIGALGO" && [[ -r "$HOSTCERT" ]] && \
                    sigalg[i]="$(read_sigalg_from_file "$HOSTCERT")"
          done
     done

     if [[ $rc4_offered -eq 1 ]]; then
          "$WIDE" || pr_svrty_high "VULNERABLE (NOT ok): "
          if "$WIDE"; then
               outln "\n"
               neat_header
          fi
          for (( i=0 ; i<nr_ciphers; i++ )); do
               if ! "${ciphers_found[i]}" && ! "$SHOW_EACH_C"; then
                    continue                 # no successful connect AND not verbose displaying each cipher
               fi
               if "$WIDE"; then
                    #FIXME: JSON+CSV in wide mode is missing
                    export="${export2[i]}"
                    neat_list "${normalized_hexcode[i]}" "${ciph[i]}" "${kx[i]}" "${enc[i]}" "${ciphers_found[i]}"
                    if "$SHOW_EACH_C"; then
                         if "${ciphers_found[i]}"; then
                              pr_svrty_high "available"
                         else
                              pr_deemphasize "not a/v"
                         fi
                    fi
                    outln "${sigalg[i]}"
               fi
               if "${ciphers_found[i]}"; then
                    if ( [[ "$DISPLAY_CIPHERNAMES" =~ openssl ]] && [[ "${ciph[i]}" != "-" ]] ) || [[ "${rfc_ciph[i]}" == "-" ]]; then
                         rc4_detected+="${ciph[i]} "
                    else
                         rc4_detected+="${rfc_ciph[i]} "
                    fi
               fi
          done
          ! "$WIDE" && pr_svrty_high "$(out_row_aligned_max_width "$rc4_detected" "                                                                " $TERM_WIDTH)"
          outln
          "$WIDE" && out " " && prln_svrty_high "VULNERABLE (NOT ok)"
          fileout "$jsonID" "HIGH" "VULNERABLE, Detected ciphers: $rc4_detected" "$cve" "$cwe" "$hint"
     elif [[ $nr_ciphers -eq 0 ]]; then
          prln_local_problem "No RC4 Ciphers configured in $OPENSSL"
          fileout "$jsonID" "WARN" "RC4 ciphers not supported by local OpenSSL ($OPENSSL)"
     else
          prln_svrty_good "no RC4 ciphers detected (OK)"
          fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
     fi
     outln

     "$using_sockets" && HAS_DH_BITS="$has_dh_bits"
     tmpfile_handle ${FUNCNAME[0]}.txt
     [[ $sclient_success -ge 6 ]] && return 1
     return 0
}


run_youknowwho() {
    local cve="CVE-2013-2566"
    local cwe="CWE-310"
    # NOT FIXME as there's no code: http://www.isg.rhul.ac.uk/tls/
    # http://blog.cryptographyengineering.com/2013/03/attack-of-week-rc4-is-kind-of-broken-in.html
    return 0
    # in a nutshell: don't use RC4, really not!
}

    # https://www.usenix.org/conference/woot13/workshop-program/presentation/smyth
    # https://secure-resumption.com/tlsauth.pdf
run_tls_truncation() {
    #FIXME: difficult to test, is there any test available: pls let me know
        :
}

# Test for various server implementation errors that aren't tested for elsewhere.
# Inspired by https://datatracker.ietf.org/doc/draft-ietf-tls-grease.
run_grease() {
     local -i success
     local bug_found=false
     local normal_hello_ok=false
     local cipher_list proto selected_cipher selected_cipher_hex="" extn rnd_bytes
     local alpn_proto alpn alpn_list_len_hex extn_len_hex
     local selected_alpn_protocol grease_selected_alpn_protocol
     local ciph list temp curve_found
     local -i i j rnd alpn_list_len extn_len debug_level=""
     local -i ret=0
     # Note: The following values were taken from https://datatracker.ietf.org/doc/draft-ietf-tls-grease.
     # These arrays may need to be updated if the values change in the final version of this document.
     local -a -r grease_cipher_suites=( "0a,0a" "1a,1a" "2a,2a" "3a,3a" "4a,4a" "5a,5a" "6a,6a" "7a,7a" "8a,8a" "9a,9a" "aa,aa" "ba,ba" "ca,ca" "da,da" "ea,ea" "fa,fa" )
     local -a -r grease_supported_groups=( "0a,0a" "1a,1a" "2a,2a" "3a,3a" "4a,4a" "5a,5a" "6a,6a" "7a,7a" "8a,8a" "9a,9a" "aa,aa" "ba,ba" "ca,ca" "da,da" "ea,ea" "fa,fa" )
     local -a -r grease_extn_values=( "0a,0a" "1a,1a" "2a,2a" "3a,3a" "4a,4a" "5a,5a" "6a,6a" "7a,7a" "8a,8a" "9a,9a" "aa,aa" "ba,ba" "ca,ca" "da,da" "ea,ea" "fa,fa" )
     local -r ecdhe_ciphers="cc,14, cc,13, c0,30, c0,2c, c0,28, c0,24, c0,14, c0,0a, c0,9b, cc,a9, cc,a8, c0,af, c0,ad, c0,77, c0,73, c0,19, cc,ac, c0,38, c0,36, c0,49, c0,4d, c0,5d, c0,61, c0,71, c0,87, c0,8b, c0,2f, c0,2b, c0,27, c0,23, c0,13, c0,09, c0,ae, c0,ac, c0,76, c0,72, c0,18, c0,37, c0,35, c0,9a, c0,48, c0,4c, c0,5c, c0,60, c0,70, c0,86, c0,8a, c0,11, c0,07, c0,16, c0,33, c0,12, c0,08, c0,17, c0,34, c0,10, c0,06, c0,15, c0,3b, c0,3a, c0,39"
     local jsonID="GREASE"

     outln; pr_headline " Testing for server implementation bugs "; outln "\n"

     # Many of the following checks work by modifying the "basic" call to
     # tls_sockets() and assuming the tested-for bug is present if the
     # connection fails. However, this only works if the connection succeeds
     # with the "basic" call. So, keep trying different "basic" calls until
     # one is found that succeeds.
     for (( i=0; i < 5; i++ )); do
          case $i in
               0) proto="03" ; cipher_list="$TLS12_CIPHER" ;;
               2) proto="02" ; cipher_list="$TLS_CIPHER" ;;
               3) proto="01" ; cipher_list="$TLS_CIPHER" ;;
               4) proto="00" ; cipher_list="$TLS_CIPHER" ;;
          esac
          tls_sockets "$proto" "$cipher_list"
          success=$?
          if [[ $success -eq 0 ]] || [[ $success -eq 2 ]]; then
               break
          fi
     done
     if [[ $success -eq 0 ]] || [[ $success -eq 2 ]]; then
          selected_cipher=$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
          if [[ $TLS_NR_CIPHERS -ne 0 ]]; then
               for (( i=0; i < TLS_NR_CIPHERS; i++ )); do
                    [[ "$selected_cipher" == "${TLS_CIPHER_RFC_NAME[i]}" ]] && selected_cipher_hex="${TLS_CIPHER_HEXCODE[i]}" && break
               done
          elif "$HAS_SSL2"; then
               selected_cipher_hex="$($OPENSSL ciphers -V -tls1 'ALL:COMPLEMENTOFALL' | awk '/'" $selected_cipher "'/ { print $1 }')"
          elif "$HAS_CIPHERSUITES"; then
               selected_cipher_hex="$($OPENSSL ciphers -V -ciphersuites "$TLS13_OSSL_CIPHERS" 'ALL:COMPLEMENTOFALL'| awk '/'" $selected_cipher "'/ { print $1 }')"
          else
               selected_cipher_hex="$($OPENSSL ciphers -V 'ALL:COMPLEMENTOFALL'| awk '/'" $selected_cipher "'/ { print $1 }')"
          fi
          if [[ -n "$selected_cipher_hex" ]]; then
               normal_hello_ok=true
               selected_cipher_hex="${selected_cipher_hex:2:2},${selected_cipher_hex:7:2}"
          fi
     else
          proto="03"
     fi

     # Test for yaSSL bug - server only looks at second byte of each cipher
     # suite listed in ClientHello (see issue #793). First check to see if
     # server ignores the ciphers in the ClientHello entirely, then check to
     # see if server only looks at second byte of each offered cipher.

     # Send a list of non-existent ciphers where the second byte does not match
     # any existing cipher.

     # Need to ensure that $TEMPDIR/$NODEIP.parse_tls_serverhello.txt contains the results of the
     # most recent calls to tls_sockets even if tls_sockets is not successful. Setting $DEBUG to
     # a non-zero value ensures this. Setting it to 1 prevents any extra information from being
     # displayed.
     debug_level="$DEBUG"
     [[ $DEBUG -eq 0 ]] && DEBUG=1
     debugme echo -e "\nSending ClientHello with non-existent ciphers."
     tls_sockets "$proto" "de,d0, de,d1, d3,d2, de,d3, 00,ff"
     success=$?
     if [[ $success -eq 0 ]] || [[ $success -eq 2 ]]; then
          prln_svrty_medium " Server claims to support non-existent cipher suite."
          fileout "$jsonID" "MEDIUM" "Server claims to support non-existent cipher suite."
          bug_found=true
     elif grep -q "The ServerHello specifies a cipher suite that wasn't included in the ClientHello" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" ; then
          prln_svrty_medium " Server responded with a ServerHello rather than an alert even though it doesn't support any of the client-offered cipher suites."
          fileout "$jsonID" "MEDIUM" "Server responded with a ServerHello rather than an alert even though it doesn't support any of the client-offered cipher suites."
          bug_found=true
     else
           # Send a list of non-existent ciphers such that for each cipher that
           # is defined, there is one in the list that matches in the second byte
           # (but make sure list contains at more 127 ciphers).
           debugme echo -e "\nSending ClientHello with non-existent ciphers, but that match existing ciphers in second byte."
           tls_sockets "$proto" "de,01, de,02, de,03, de,04, de,05, de,06, de,07, de,08, de,09, de,0a, de,0b, de,0c, de,0d, de,0e, de,0f, de,10, de,11, de,12, de,13, de,14, de,15, de,16, de,17, de,18, de,19, de,1a, de,1b, de,23, de,24, de,25, de,26, de,27, de,28, de,29, de,2a, de,2b, de,2c, de,2d, de,2e, de,2f, de,30, de,31, de,32, de,33, de,34, de,35, de,36, de,37, de,38, de,39, de,3a, de,3b, de,3c, de,3d, de,3e, de,3f, de,40, de,41, de,42, de,43, de,44, de,45, de,46, de,60, de,61, de,62, de,63, de,64, de,65, de,66, de,67, de,68, de,69, de,6a, de,6b, de,6c, de,6d, de,72, de,73, de,74, de,75, de,76, de,77, de,78, de,79, de,84, de,85, de,86, de,87, de,88, de,89, de,96, de,97, de,98, de,99, de,9a, de,9b, de,9c, de,9d, de,9e, de,9f, de,a0, de,a1, de,a2, de,a3, de,a4, de,a5, de,a6, de,a7, de,ba, de,bb, de,bc, de,bd, de,be, de,bf, de,c0, de,c1, de,c2, de,c3, de,c4, de,c5, 00,ff"
           success=$?
           if [[ $success -eq 0 ]] || [[ $success -eq 2 ]]; then
                prln_svrty_medium " Server claims to support non-existent cipher suite."
                fileout "$jsonID" "MEDIUM" "Server claims to support non-existent cipher suite."
                bug_found=true
           elif grep -q " The ServerHello specifies a cipher suite that wasn't included in the ClientHello" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" ; then
               prln_svrty_medium " Server only compares against second byte in each cipher suite in ClientHello."
               fileout "$jsonID" "MEDIUM" "Server only compares against second byte in each cipher suite in ClientHello."
               bug_found=true
          fi
     fi
     DEBUG="$debug_level"

     # Check that server ignores unrecognized extensions
     # see https://datatracker.ietf.org/doc/draft-ietf-tls-grease
     if "$normal_hello_ok" && [[ "$proto" != "00" ]]; then
          # Try multiple different randomly-generated GREASE extensions,
          # but make final test use zero-length extension value, just to
          # be sure that works before testing server with a zero-length
          # extension as the final extension.
          for (( i=1; i <= 5; i++ )); do
               # Create a random extension using one of the GREASE values.
               rnd=$RANDOM%${#grease_extn_values[@]}
               extn="${grease_extn_values[rnd]}"
               if [[ $i -eq 5 ]]; then
                    extn_len=0
               else
                    # Not sure what a good upper bound is here, but a key_share
                    # extension with an ffdhe8192 would be over 1024 bytes.
                    extn_len=$RANDOM%1024
               fi
               extn_len_hex=$(printf "%04x" $extn_len)
               extn+=",${extn_len_hex:0:2},${extn_len_hex:2:2}"
               for (( j=0; j <= extn_len-2; j=j+2 )); do
                    rnd_bytes="$(printf "%04x" $RANDOM)"
                    extn+=",${rnd_bytes:0:2},${rnd_bytes:2:2}"
               done
               if [[ $j -lt $extn_len ]]; then
                    rnd_bytes="$(printf "%04x" $RANDOM)"
                    extn+=",${rnd_bytes:0:2}"
               fi
               if [[ $DEBUG -ge 2 ]]; then
                    echo -en "\nSending ClientHello with unrecognized extension"
                    [[ $DEBUG -ge 3 ]] && echo -n ": $extn"
                    echo ""
               fi
               tls_sockets "$proto" "$cipher_list" "" "$extn"
               success=$?
               if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
                    break
               fi
          done
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               prln_svrty_medium " Server fails if ClientHello contains an unrecognized extension."
               outln "    extension used in failed test: $extn"
               fileout "$jsonID" "MEDIUM" "Server fails if ClientHello contains an unrecognized extension: $extn"
               bug_found=true
          else
               # Check for inability to handle empty last extension (see PR #792 and
               # https://www.ietf.org/mail-archive/web/tls/current/msg19720.html).
               # (Since this test also uses an unrecognized extension, only run this
               # test if the previous test passed, and use the final extension value
               # from that test to ensure that the only difference is the location
               # of the extension.)

               # The "extra extensions" parameter needs to include the padding and
               # heartbeat extensions, since otherwise prepare_tls_clienthello()
               # will add these extensions to the end of the ClientHello.
               debugme echo -e "\nSending ClientHello with empty last extension."
               tls_sockets "$proto" "$cipher_list" "" "
                 00,0f, 00,01, 01,
                 00,15, 00,56,
                   00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,
                   00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,
                   00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,
                   00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,
                 $extn"
               success=$?
               if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
                    prln_svrty_medium " Server fails if last extension in ClientHello is empty."
                    fileout "$jsonID" "MEDIUM" "Server fails if last extension in ClientHello is empty."
                    bug_found=true
               fi
          fi
     fi

     # Check for SERVER_SIZE_LIMIT_BUG.
     # Send a ClientHello with 129 cipher suites (including 0x00,0xff) to see
     # if adding a 129th cipher to the list causes a failure.
#TODO: we need to clarify whether the mit is hit at 128 or 129 ciphers.
     if "$normal_hello_ok" && [[ "$proto" == 03 ]]; then
          debugme echo -e "\nSending ClientHello with 129 cipher suites."
          tls_sockets "$proto" "00,27, $cipher_list"
          success=$?
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               prln_svrty_medium " Server fails if ClientHello includes more than 128 cipher suites."
               fileout "$jsonID" "MEDIUM" "Server fails if ClientHello includes more than 128 cipher suites."
               SERVER_SIZE_LIMIT_BUG=true
               bug_found=true
          fi
     fi

     # Check for ClientHello size bug. According to RFC 7586 "at least one TLS
     # implementation is known to hang the connection when [a] ClientHello
     # record [with a length between 256 and 511 bytes] is received."
     # If the length of the host name is more than 75 bytes (which would make
     # $SNI more than 87 bytes), then the ClientHello would be more than 511
     # bytes if the server_name extension were included. Removing the SNI
     # extension, however, may not be an option, since the server may reject the
     # connection attempt for that reason.
     if "$normal_hello_ok" && [[ "$proto" != 00 ]] && [[ ${#SNI} -le 87 ]]; then
          # Normally prepare_tls_clienthello() will add a padding extension with a length
          # that will make the ClientHello be 512 bytes in length. Providing an "extra
          # extensions" parameter with a short padding extension prevents that.
          debugme echo -e "\nSending ClientHello with length between 256 and 511 bytes."
          tls_sockets "$proto" "$cipher_list" "" "00,15,00,01,00"
          success=$?
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               prln_svrty_medium " Server fails if ClientHello is between 256 and 511 bytes in length."
               fileout "$jsonID" "MEDIUM" "Server fails if ClientHello is between 256 and 511 bytes in length."
               bug_found=true
          fi
     fi

     # Check that server ignores unrecognized cipher suite values
     # see https://datatracker.ietf.org/doc/draft-ietf-tls-grease
     if "$normal_hello_ok"; then
          list=""
          for ciph in "${grease_cipher_suites[@]}"; do
               list+=", $ciph"
          done
          debugme echo -e "\nSending ClientHello with unrecognized cipher suite values."
          tls_sockets "$proto" "${list:2}, $selected_cipher_hex, 00,ff"
          success=$?
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               prln_svrty_medium " Server fails if ClientHello contains unrecognized cipher suite values."
               fileout "$jsonID" "MEDIUM" "Server fails if ClientHello contains unrecognized cipher suite values."
               bug_found=true
          fi
     fi

     # Check that servers that support ECDHE cipher suites ignore
     # unrecognized named group values.
     # see https://datatracker.ietf.org/doc/draft-ietf-tls-grease
     if [[ "$proto" != "00" ]]; then
          # Send a ClientHello that lists all of the ECDHE cipher suites
          tls_sockets "$proto" "$ecdhe_ciphers, 00,ff" "ephemeralkey"
          success=$?
          if [[ $success -eq 0 ]] || [[ $success -eq 2 ]]; then
               # Send the same ClientHello as before but with an unrecognized
               # named group value added. Make the unrecognized value the first
               # one in the list replacing one of the values in the original list,
               # but don't replace the value that was selected by the server.
               rnd=$RANDOM%${#grease_supported_groups[@]}
               temp=$(awk -F': ' '/^Server Temp Key/ { print $2 }' "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")
               curve_found="${temp%%,*}"
               if [[ "$curve_found" == "ECDH" ]]; then
                    curve_found="${temp#*, }"
                    curve_found="${curve_found%%,*}"
               fi
               if [[ "$curve_found" == "B-571" ]]; then
                    extn="
                    00, 0a,                    # Type: Supported Elliptic Curves , see RFC 4492
                    00, 3e, 00, 3c,            # lengths
                    ${grease_supported_groups[rnd]}, 00, 0e, 00, 19, 00, 1c, 00, 1e, 00, 0b, 00, 0c, 00, 1b,
                    00, 18, 00, 09, 00, 0a, 00, 1a, 00, 16, 00, 17, 00, 1d, 00, 08,
                    00, 06, 00, 07, 00, 14, 00, 15, 00, 04, 00, 05, 00, 12, 00, 13,
                    00, 01, 00, 02, 00, 03, 00, 0f, 00, 10, 00, 11"
               else
                    extn="
                    00, 0a,                    # Type: Supported Elliptic Curves , see RFC 4492
                    00, 3e, 00, 3c,            # lengths
                    ${grease_supported_groups[rnd]}, 00, 0d, 00, 19, 00, 1c, 00, 1e, 00, 0b, 00, 0c, 00, 1b,
                    00, 18, 00, 09, 00, 0a, 00, 1a, 00, 16, 00, 17, 00, 1d, 00, 08,
                    00, 06, 00, 07, 00, 14, 00, 15, 00, 04, 00, 05, 00, 12, 00, 13,
                    00, 01, 00, 02, 00, 03, 00, 0f, 00, 10, 00, 11"
               fi
               debugme echo -e "\nSending ClientHello with unrecognized named group value in supported_groups extension."
               tls_sockets "$proto" "$ecdhe_ciphers, 00,ff" "" "$extn"
               success=$?
               if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
                    prln_svrty_medium " Server fails if ClientHello contains a supported_groups extension with an unrecognized named group value (${grease_supported_groups[rnd]})."
                    fileout "$jsonID" "MEDIUM" "Server fails if ClientHello contains a supported_groups extension with an unrecognized named group value (${grease_supported_groups[rnd]})."
                    bug_found=true
               fi
          fi
     fi

     # Check that servers that support the ALPN extension ignore
     # unrecognized ALPN values.
     # see https://datatracker.ietf.org/doc/draft-ietf-tls-grease
     if "$normal_hello_ok" && [[ -z $STARTTLS ]] && [[ "$proto" != "00" ]]; then
          for alpn_proto in $ALPN_PROTOs; do
               alpn+=",$(printf "%02x" ${#alpn_proto}),$(string_to_asciihex "$alpn_proto")"
          done
          alpn_list_len=${#alpn}/3
          alpn_list_len_hex=$(printf "%04x" $alpn_list_len)
          extn_len=$alpn_list_len+2
          extn_len_hex=$(printf "%04x" $extn_len)
          tls_sockets "$proto" "$cipher_list" "all" "00,10,${extn_len_hex:0:2},${extn_len_hex:2:2},${alpn_list_len_hex:0:2},${alpn_list_len_hex:2:2}$alpn"
          success=$?
          if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
               prln_svrty_medium " Server fails if ClientHello contains an application_layer_protocol_negotiation extension."
               fileout "$jsonID" "MEDIUM" "Server fails if ClientHello contains an application_layer_protocol_negotiation extension."
               bug_found=true
          else
               selected_alpn_protocol="$(grep "ALPN protocol:" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" | sed 's/ALPN protocol:  //')"
               # If using a "normal" ALPN extension worked, then add an unrecognized
               # ALPN value to the beginning of the extension and try again.
               alpn_proto="ignore/$selected_alpn_protocol"
               alpn=",$(printf "%02x" ${#alpn_proto}),$(string_to_asciihex "$alpn_proto")$alpn"
               alpn_list_len=${#alpn}/3
               alpn_list_len_hex=$(printf "%04x" $alpn_list_len)
               extn_len=$alpn_list_len+2
               extn_len_hex=$(printf "%04x" $extn_len)
               debugme echo -e "\nSending ClientHello with unrecognized ALPN value in application_layer_protocol_negotiation extension."
               tls_sockets "$proto" "$cipher_list" "all" "00,10,${extn_len_hex:0:2},${extn_len_hex:2:2},${alpn_list_len_hex:0:2},${alpn_list_len_hex:2:2}$alpn"
               success=$?
               if [[ $success -ne 0 ]] && [[ $success -ne 2 ]]; then
                    prln_svrty_medium " Server fails if ClientHello contains an application_layer_protocol_negotiation extension with an unrecognized ALPN value."
                    fileout "$jsonID" "MEDIUM" "erver fails if ClientHello contains an application_layer_protocol_negotiation extension with an unrecognized ALPN value."
                    bug_found=true
               else
                    grease_selected_alpn_protocol="$(grep "ALPN protocol:" "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt" | sed 's/ALPN protocol:  //')"
                    if [[ -z "$grease_selected_alpn_protocol" ]] && [[ -n "$selected_alpn_protocol" ]]; then
                         prln_svrty_medium " Server did not ignore unrecognized ALPN value in the application_layer_protocol_negotiation extension."
                         fileout "$jsonID" "MEDIUM" "Server did not ignore unrecognized ALPN value in the application_layer_protocol_negotiation extension."
                         bug_found=true
                    elif [[ "$grease_selected_alpn_protocol" =~ ignore/ ]]; then
                         prln_svrty_medium " Server selected \"ignore/\" ALPN value in the application_layer_protocol_negotiation extension."
                         fileout "$jsonID" "MEDIUM" "Server selected \"ignore/\" ALPN value in the application_layer_protocol_negotiation extension."
                         bug_found=true
                    fi
               fi
          fi
     fi

     # TODO: For servers that support TLSv1.3, check that servers ignore
     # an unrecognized named group value along with a corresponding
     # unrecognized key share
     # see https://www.ietf.org/mail-archive/web/tls/current/msg22322.html
     # and https://www.ietf.org/mail-archive/web/tls/current/msg22319.html

     # TODO: For servers that support TLSv1.3, check that servers ignore unrecognized
     # values in the supported_versions extension.
     # see https://www.ietf.org/mail-archive/web/tls/current/msg22319.html

     # TODO: For servers that support TLSv1.3, check that servers don't require the
     # psk_key_exchange_modes extension to be present in the ClientHello.

     if ! "$bug_found"; then
          outln " No bugs found."
          fileout "$jsonID" "OK" "No bugs found."
          #return 0
     else
          #return 1
          :
     fi
     return $ret
     #FIXME: No client side error cases where we want to return 1?
}

# If the server supports any non-PSK cipher suites that use RSA key transport,
# check if the server is vulnerable to Bleichenbacher's Oracle Threat (ROBOT) attacks.
# See "Return Of Bleichenbacher's Oracle Threat (ROBOT)" by Hanno Böck,
# Juraj Somorovsky, and Craig Young (https://robotattack.org).
#
run_robot() {
     local tls_hexcode="03"
     # A list of all non-PSK cipher suites that use RSA key transport
     local cipherlist="00,9d, c0,a1, c0,9d, 00,3d, 00,35, 00,c0, 00,84, c0,3d, c0,51, c0,7b, ff,00, ff,01, ff,02, ff,03, c0,a0, c0,9c, 00,9c, 00,3c, 00,2f, 00,ba, 00,96, 00,41, 00,07, c0,3c, c0,50, c0,7a, 00,05, 00,04, 00,0a, fe,ff, ff,e0, 00,62, 00,09, 00,61, fe,fe, ff,e1, 00,64, 00,60, 00,08, 00,06, 00,03, 00,3b, 00,02, 00,01"
     # A list of all non-PSK cipher suites that use RSA key transport and that use AES in either GCM or CBC mode.
     local aes_gcm_cbc_cipherlist="00,9d, 00,9c, 00,3d, 00,35, 00,3c, 00,2f"
     local padded_pms encrypted_pms cke_prefix client_key_exchange rnd_pad
     local rnd_pms="aa112233445566778899112233445566778899112233445566778899112233445566778899112233445566778899"
     local change_cipher_spec finished resp
     local -a response
     local -i i subret len iteration testnum pubkeybits pubkeybytes
     local vulnerable=false send_ccs_finished=true
     local -i start_time end_time timeout=$MAX_WAITSOCK
     local cve="CVE-2017-17382 CVE-2017-17427 CVE-2017-17428 CVE-2017-13098 CVE-2017-1000385 CVE-2017-13099 CVE-2016-6883 CVE-2012-5081 CVE-2017-6168"
     local cwe="CWE-203"
     local jsonID="ROBOT"

     [[ $VULN_COUNT -le $VULN_THRESHLD ]] && outln && pr_headlineln " Testing for Return of Bleichenbacher's Oracle Threat (ROBOT) vulnerability " && outln
     pr_bold " ROBOT                                     "

     if ( [[ "$STARTTLS_PROTOCOL" =~ ldap ]] || [[ "$STARTTLS_PROTOCOL" =~ irc ]] ); then
          prln_local_problem "STARTTLS/$STARTTLS_PROTOCOL and --ssl-native collide here"
          return 1
     fi

     if [[ ! "$HAS_PKUTIL" ]]; then
          prln_local_problem "Your $OPENSSL does not support the pkeyutl utility."
          fileout "$jsonID" "WARN" "$OPENSSL does not support the pkeyutl utility." "$cve" "$cwe"
          return 1
     elif ! "$HAS_PKEY"; then
          prln_local_problem "Your $OPENSSL does not support the pkey utility."
          fileout "$jsonID" "WARN" "$OPENSSL does not support the pkey utility." "$cve" "$cwe"
          return 1
     fi

     if [[ 0 -eq $(has_server_protocol tls1_2) ]]; then
          tls_hexcode="03"
     elif [[ 0 -eq $(has_server_protocol tls1_1) ]]; then
          tls_hexcode="02"
     elif [[ 0 -eq $(has_server_protocol tls1) ]]; then
          tls_hexcode="01"
     elif [[ 0 -eq $(has_server_protocol ssl3) ]]; then
          tls_hexcode="00"
     fi

     # Some hosts are only vulnerable with GCM. First send a list of
     # ciphers that use AES in GCM or CBC mode, with the GCM ciphers
     # listed first, and then try all ciphers that use RSA key transport
     # if there is no connection on the first try.
     tls_sockets "$tls_hexcode" "$aes_gcm_cbc_cipherlist, 00,ff"
     subret=$?
     if [[ $subret -eq 0 ]] || [[ $subret -eq 2 ]]; then
          cipherlist="$aes_gcm_cbc_cipherlist"
          tls_hexcode="${DETECTED_TLS_VERSION:2:2}"
     else
          if [[ "$tls_hexcode" != "03" ]]; then
               cipherlist="$(strip_inconsistent_ciphers "$tls_hexcode" ", $cipherlist")"
               cipherlist="${cipherlist:2}"
          fi
          tls_sockets "$tls_hexcode" "$cipherlist, 00,ff"
          subret=$?
          if [[ $subret -eq 2 ]]; then
               tls_hexcode="${DETECTED_TLS_VERSION:2:2}"
               cipherlist="$(strip_inconsistent_ciphers "$tls_hexcode" ", $cipherlist")"
               cipherlist="${cipherlist:2}"
          elif [[ $subret -ne 0 ]]; then
               prln_svrty_best "Server does not support any cipher suites that use RSA key transport"
               fileout "$jsonID" "OK" "not vulnerable, no RSA key transport cipher" "$cve" "$cwe"
               return 0
          fi
     fi

     # Run the tests in two iterations. In iteration 0, send 5 different client
     # key exchange (CKE) messages followed by change cipher spec (CCS) and
     # Finished messages, and check whether the server provided the same
     # response in each case. If the server didn't provide the same response
     # for all five messages in iteration 0, then it is vulnerable. Otherwise
     # try a second time (iteration 1) with the same CKE messages, but without
     # sending the CCS or Finished messages.
     # Iterations 0 and 1 are run with a short timeout waiting for the server
     # to respond to the CKE message. If the server was found to be potentially
     # vulnerable in iteration 0 or 1 and testssl.sh timed out waiting for a
     # response in some cases, then retry the test using a longer timeout value.
     for (( iteration=0; iteration < 3; iteration++ )); do
          if [[ $iteration -eq 1 ]]; then
               # If the server was found to be vulnerable in iteration 0, then
               # there's no need to try the alternative message flow.
               "$vulnerable" && continue
               send_ccs_finished=false
          elif [[ $iteration -eq 2 ]]; then
               # The tests are being rerun, so reset the vulnerable flag.
               vulnerable=false
          fi
          for (( testnum=0; testnum < 5; testnum++ )); do
               response[testnum]="untested"
          done
          for (( testnum=0; testnum < 5; testnum++ )); do
               tls_sockets "$tls_hexcode" "$cipherlist, 00,ff" "all" "" "" "false"

               # Create the padded premaster secret to encrypt. The padding should be
               # of the form "00 02 <random> 00 <TLS version> <premaster secret>."
               # However, for each test except testnum=0 the padding will be
               # made incorrect in some way, as specified below.

               # Determine the length of the public key and create the <random> bytes.
               # <random> should be a length that makes total length of $padded_pms
               # the same as the length of the public key. <random> should contain no 00 bytes.
               pubkeybits="$($OPENSSL x509 -noout -pubkey -in $HOSTCERT 2>>$ERRFILE | \
                             $OPENSSL pkey -pubin -text 2>>$ERRFILE | grep -aw "Public-Key:" | \
                             sed -e 's/.*(//' -e 's/ bit)//')"
               pubkeybytes=$pubkeybits/8
               [[ $((pubkeybits%8)) -ne 0 ]] && pubkeybytes+=1
               rnd_pad=""
               for (( len=0; len < pubkeybytes-52; len=len+2 )); do
                    rnd_pad+="abcd"
               done
               [[ $len -eq $pubkeybytes-52 ]] && rnd_pad+="ab"

               case "$testnum" in
                    # correct padding
                    0) padded_pms="0002${rnd_pad}00${DETECTED_TLS_VERSION}${rnd_pms}" ;;
                    # wrong first two bytes
                    1) padded_pms="4117${rnd_pad}00${DETECTED_TLS_VERSION}${rnd_pms}" ;;
                    # 0x00 on a wrong position
                    2) padded_pms="0002${rnd_pad}11${rnd_pms}0011" ;;
                    # no 0x00 in the middle
                    3) padded_pms="0002${rnd_pad}111111${rnd_pms}" ;;
                    # wrong version number (according to Klima / Pokorny / Rosa paper)
                    4) padded_pms="0002${rnd_pad}000202${rnd_pms}" ;;
               esac

               # Encrypt the padded premaster secret using the server's public key.
               encrypted_pms="$(asciihex_to_binary_file "$padded_pms" "/dev/stdout" | \
                    $OPENSSL pkeyutl -encrypt -certin -inkey $HOSTCERT -pkeyopt rsa_padding_mode:none 2>/dev/null | \
                    hexdump -v -e '16/1 "%02x"')"
               if [[ -z "$encrypted_pms" ]]; then
                    if [[ "$DETECTED_TLS_VERSION" == "0300" ]]; then
                         socksend ",x15, x03, x00, x00, x02, x02, x00" 0
                    else
                         socksend ",x15, x03, x01, x00, x02, x02, x00" 0
                    fi
                    close_socket
                    prln_fixme "Conversion of public key failed around line $((LINENO - 9))"
                    fileout "$jsonID" "WARN" "Conversion of public key failed around line $((LINENO - 10)) "
                    return 1
               fi

               # Create the client key exchange message.
               len=${#encrypted_pms}/2
               cke_prefix="16${DETECTED_TLS_VERSION}$(printf "%04x" $((len+6)))10$(printf "%06x" $((len+2)))$(printf "%04x" $len)"
               encrypted_pms="$cke_prefix$encrypted_pms"
               len=${#encrypted_pms}
               client_key_exchange=""
               for (( i=0; i<len; i=i+2 )); do
                   client_key_exchange+=", x${encrypted_pms:i:2}"
               done

               # The contents of change cipher spec are fixed.
               change_cipher_spec=", x14, x${DETECTED_TLS_VERSION:0:2}, x${DETECTED_TLS_VERSION:2:2}, x00, x01, x01"

               # Send an arbitrary Finished message.
               finished=", x16, x${DETECTED_TLS_VERSION:0:2}, x${DETECTED_TLS_VERSION:2:2}
                         , x00, x40, x6e, x49, x65, x68, x00, x46, x79, xfd, x5a, x57, xdc
                         , x3e, xef, xb2, xd2, xac, xe0, x8c, x54, x2d, x5f, x00, x87, xdb
                         , xb6, xe3, x77, x2c, x9d, x88, x27, x38, x98, x7d, xcd, x7e, xac
                         , xdd, x5d, x72, xbe, x24, x0d, x20, x36, x14, x0e, x94, x51, xde
                         , xa0, xb6, xc7, x56, x28, xd8, xa1, xcb, x24, xb9, x03, xd0, x7c, x50"

               if "$send_ccs_finished"; then
                    debugme echo -en "\nsending client key exchange, change cipher spec, finished... "
                    socksend "$client_key_exchange$change_cipher_spec$finished" $USLEEP_SND
               else
                    debugme echo -en "\nsending client key exchange... "
                    socksend "$client_key_exchange" $USLEEP_SND
               fi
               debugme echo "reading server error response..."
               start_time=$(LC_ALL=C date "+%s")
               sockread_serverhello 32768 $timeout
               subret=$?
               if [[ $subret -eq 0 ]]; then
                    end_time=$(LC_ALL=C date "+%s")
                    resp=$(hexdump -v -e '16/1 "%02x"' "$SOCK_REPLY_FILE")
                    response[testnum]="${resp%%[!0-9A-F]*}"
                    # The first time a response is received to a client key
                    # exchange message, measure the amount of time it took to
                    # receive a response and set the timeout value for future
                    # tests to 2 seconds longer than it took to receive a response.
                    [[ $iteration -ne 2 ]] && [[ $timeout -eq $MAX_WAITSOCK ]] && \
                         [[ $((end_time-start_time)) -lt $((MAX_WAITSOCK-2)) ]] && \
                         timeout=$((end_time-start_time+2))
               else
                    response[testnum]="Timeout waiting for alert"
               fi
               debugme echo -e "\nresponse[$testnum] = ${response[testnum]}"
               [[ $DEBUG -ge 3 ]] && [[ $subret -eq 0 ]] && parse_tls_serverhello "${response[testnum]}"
               close_socket

               # Don't continue testing if it has already been determined that
               # tests need to be rerun with a longer timeout.
               if [[ $iteration -ne 2 ]]; then
                    for (( i=1; i <= testnum; i++ )); do
                         if [[ "${response[i]}" != "${response[$((i-1))]}" ]] && \
                            ( [[ "${response[i]}" == "Timeout waiting for alert" ]] || \
                              [[ "${response[$((i-1))]}" == "Timeout waiting for alert" ]] ); then
                              vulnerable=true
                              break
                         fi
                    done
                    "$vulnerable" && break
               fi
               # Don't continue testing if it has already been determined that the server is
               # strongly vulnerable.
               if [[ $testnum -eq 2 ]]; then
                    [[ "${response[1]}" != "${response[2]}" ]] && break
               elif [[ $testnum -eq 3 ]]; then
                    [[ "${response[2]}" != "${response[3]}" ]] && break
                    [[ "${response[0]}" != "${response[1]}" ]] && break
               fi
          done
          # If the server provided the same error message for all tests, then this
          # is an indication that the server is not vulnerable.
          if [[ "${response[0]}" != "${response[1]}" ]] || [[ "${response[1]}" != "${response[2]}" ]] || \
             [[ "${response[2]}" != "${response[3]}" ]] || [[ "${response[3]}" != "${response[4]}" ]]; then
               vulnerable=true

               # If the test was run with a short timeout and was found to be
               # potentially vulnerable due to some tests timing out, then
               # verify the results by rerunning with a longer timeout.
               if [[ $timeout -eq $MAX_WAITSOCK ]]; then
                    break
               elif [[ "${response[0]}" == "Timeout waiting for alert" ]] || \
                    [[ "${response[1]}" == "Timeout waiting for alert" ]] || \
                    [[ "${response[2]}" == "Timeout waiting for alert" ]] || \
                    [[ "${response[3]}" == "Timeout waiting for alert" ]] || \
                    [[ "${response[4]}" == "Timeout waiting for alert" ]]; then
                    timeout=10
               else
                    break
               fi
          fi
          ! "$vulnerable" && [[ $iteration -eq 1 ]] && break
     done

     if "$vulnerable"; then
          if [[ "${response[1]}" == "${response[2]}" ]] && [[ "${response[2]}" == "${response[3]}" ]]; then
               pr_svrty_medium "VULNERABLE (NOT ok)"; outln " - weakly vulnerable as the attack would take too long"
               fileout "$jsonID" "MEDIUM" "VULNERABLE, but the attack would take too long" "$cve" "$cwe"
          else
               prln_svrty_critical "VULNERABLE (NOT ok)"
               fileout "$jsonID" "CRITICAL" "VULNERABLE" "$cve" "$cwe"
          fi
     else
          prln_svrty_best "not vulnerable (OK)"
          fileout "$jsonID" "OK" "not vulnerable" "$cve" "$cwe"
     fi
     return 0
}

old_fart() {
     out "Get precompiled bins or compile "
     pr_url "https://github.com/PeterMosmans/openssl"
     outln "."
     fileout_insert_warning "old_fart" "WARN" "Your $OPENSSL $OSSL_VER version is an old fart... . It doesn\'t make much sense to proceed. Get precompiled bins or compile https://github.com/PeterMosmans/openssl ."
     fatal "Your $OPENSSL $OSSL_VER version is an old fart... . It doesn't make much sense to proceed." $ERR_OSSLBIN
}

# try very hard to determine the install path to get ahold of the mapping file and the CA bundles
# TESTSSL_INSTALL_DIR can be supplied via environment so that the cipher mapping and CA bundles can be found
# www.carbonwind.net/TLS_Cipher_Suites_Project/tls_ssl_cipher_suites_simple_table_all.htm
get_install_dir() {
     [[ -z "$TESTSSL_INSTALL_DIR" ]] && TESTSSL_INSTALL_DIR="$(dirname "${BASH_SOURCE[0]}")"

     if [[ -r "$RUN_DIR/etc/cipher-mapping.txt" ]]; then
          CIPHERS_BY_STRENGTH_FILE="$RUN_DIR/etc/cipher-mapping.txt"
          [[ -z "$TESTSSL_INSTALL_DIR" ]] && TESTSSL_INSTALL_DIR="$RUN_DIR"          # probably TESTSSL_INSTALL_DIR
     fi

     [[ -r "$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt"
     if [[ ! -r "$CIPHERS_BY_STRENGTH_FILE" ]]; then
          [[ -r "$RUN_DIR/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$RUN_DIR/cipher-mapping.txt"
          [[ -r "$TESTSSL_INSTALL_DIR/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/cipher-mapping.txt"
     fi

     # we haven't found the cipher file yet...
     if [[ ! -r "$CIPHERS_BY_STRENGTH_FILE" ]] && type -p readlink &>/dev/null ; then
          readlink -f ls &>/dev/null && \
               TESTSSL_INSTALL_DIR="$(readlink -f "$(basename "${BASH_SOURCE[0]}")")" || \
               TESTSSL_INSTALL_DIR="$(readlink "$(basename "${BASH_SOURCE[0]}")")"
               # not sure whether Darwin has -f
          TESTSSL_INSTALL_DIR="$(dirname "$TESTSSL_INSTALL_DIR" 2>/dev/null)"
          [[ -r "$TESTSSL_INSTALL_DIR/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/cipher-mapping.txt"
          [[ -r "$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt"
     fi

     # still no cipher mapping file:
     if [[ ! -r "$CIPHERS_BY_STRENGTH_FILE" ]] && type -p realpath &>/dev/null ; then
          TESTSSL_INSTALL_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
          CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt"
          [[ -r "$TESTSSL_INSTALL_DIR/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/cipher-mapping.txt"
     fi

     # still no cipher mapping file (and realpath is not present):
     if [[ ! -r "$CIPHERS_BY_STRENGTH_FILE" ]] && type -p readlink &>/dev/null ; then
         readlink -f ls &>/dev/null && \
              TESTSSL_INSTALL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || \
              TESTSSL_INSTALL_DIR="$(dirname "$(readlink "${BASH_SOURCE[0]}")")"
              # not sure whether Darwin has -f
          CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/etc/cipher-mapping.txt"
          [[ -r "$TESTSSL_INSTALL_DIR/cipher-mapping.txt" ]] && CIPHERS_BY_STRENGTH_FILE="$TESTSSL_INSTALL_DIR/cipher-mapping.txt"
     fi

     if [[ ! -r "$CIPHERS_BY_STRENGTH_FILE" ]]; then
          DISPLAY_CIPHERNAMES="no-rfc"
          debugme echo "$CIPHERS_BY_STRENGTH_FILE"
          prln_warning "\nATTENTION: No cipher mapping file found!"
          outln "Please note from 2.9 on $PROG_NAME needs files in \"\$TESTSSL_INSTALL_DIR/etc/\" to function correctly."
          outln
          ignore_no_or_lame "Type \"yes\" to ignore this warning and proceed at your own risk" "yes"
          [[ $? -ne 0 ]] && exit $ERR_RESOURCE
     fi

     TLS_DATA_FILE="$TESTSSL_INSTALL_DIR/etc/tls_data.txt"
     if [[ ! -r "$TLS_DATA_FILE" ]]; then
          prln_warning "\nATTENTION: No TLS data file found -- needed for socket-based handshakes"
          outln "Please note from 2.9 on $PROG_NAME needs files in \"\$TESTSSL_INSTALL_DIR/etc/\" to function correctly."
          outln
          ignore_no_or_lame "Type \"yes\" to ignore this warning and proceed at your own risk" "yes"
          [[ $? -ne 0 ]] && exit $ERR_RESOURCE
     else
          :     # see #705, in a nutshell: not portable to initialize a global array inside a function. Thus it'll be done in main part below
     fi
}


test_openssl_suffix() {
     local naming_ext="$(uname).$(uname -m)"
     local uname_arch="$(uname -m)"
     local myarch_suffix=""

     [[ $uname_arch =~ 64 ]] && myarch_suffix=64 || myarch_suffix=32
     if [[ -f "$1/openssl" ]] && [[ -x "$1/openssl" ]]; then
          OPENSSL="$1/openssl"
          return 0
     elif [[ -f "$1/openssl.$naming_ext" ]] && [[ -x "$1/openssl.$naming_ext" ]]; then
          OPENSSL="$1/openssl.$naming_ext"
          return 0
     elif [[ -f "$1/openssl.$uname_arch" ]] && [[ -x "$1/openssl.$uname_arch" ]]; then
          OPENSSL="$1/openssl.$uname_arch"
          return 0
     elif [[ -f "$1/openssl$myarch_suffix" ]] && [[ -x "$1/openssl$myarch_suffix" ]]; then
          OPENSSL="$1/openssl$myarch_suffix"
          return 0
     fi
     return 1
}


find_openssl_binary() {
     local s_client_has=$TEMPDIR/s_client_has.txt
     local s_client_starttls_has=$TEMPDIR/s_client_starttls_has.txt
     local openssl_location cwd=""
     local ossl_wo_dev_info
     local curve
     local -a curves_ossl=("sect163k1" "sect163r1" "sect163r2" "sect193r1" "sect193r2" "sect233k1" "sect233r1" "sect239k1" "sect283k1" "sect283r1" "sect409k1" "sect409r1" "sect571k1" "sect571r1" "secp160k1" "secp160r1" "secp160r2" "secp192k1" "prime192v1" "secp224k1" "secp224r1" "secp256k1" "prime256v1" "secp384r1" "secp521r1" "brainpoolP256r1" "brainpoolP384r1" "brainpoolP512r1" "X25519" "X448")

     # 0. check environment variable whether it's executable
     if [[ -n "$OPENSSL" ]] && [[ ! -x "$OPENSSL" ]]; then
          prln_warning "\ncannot find specified (\$OPENSSL=$OPENSSL) binary."
          tmln_out " Looking some place else ..."
     elif [[ -x "$OPENSSL" ]]; then
          :    # 1. all ok supplied $OPENSSL was found and has executable bit set -- testrun comes below
     elif [[ -e "/mnt/c/Windows/System32/bash.exe" ]] && test_openssl_suffix "$(dirname "$(type -p openssl)")"; then
          # 2. otherwise, only if on Bash on Windows, use system binaries only.
          SYSTEM2="WSL"
     elif test_openssl_suffix "$TESTSSL_INSTALL_DIR"; then
          :    # 3. otherwise try openssl in path of testssl.sh
     elif test_openssl_suffix "$TESTSSL_INSTALL_DIR/bin"; then
          :    # 4. otherwise here, this is supposed to be the standard --platform independent path in the future!!!
     elif test_openssl_suffix "$(dirname "$(type -p openssl)")"; then
          :    # 5. we tried hard and failed, so now we use the system binaries
     fi

     # no ERRFILE initialized yet, thus we use /dev/null for stderr directly
     $OPENSSL version -a 2>/dev/null >/dev/null
     if [[ $? -ne 0 ]] || [[ ! -x "$OPENSSL" ]]; then
          fatal "cannot exec or find any openssl binary" $ERR_OSSLBIN
     fi

     # http://www.openssl.org/news/openssl-notes.html
     OSSL_NAME=$($OPENSSL version 2>/dev/null | awk '{ print $1 }')
     OSSL_VER=$($OPENSSL version 2>/dev/null | awk -F' ' '{ print $2 }')
     OSSL_VER_MAJOR="${OSSL_VER%%\.*}"
     ossl_wo_dev_info="${OSSL_VER%%-*}"
     OSSL_VER_MINOR="${ossl_wo_dev_info#$OSSL_VER_MAJOR\.}"
     OSSL_VER_MINOR="${OSSL_VER_MINOR%%[a-zA-Z]*}"
     OSSL_VER_APPENDIX="${OSSL_VER#$OSSL_VER_MAJOR\.$OSSL_VER_MINOR}"
     OSSL_VER_PLATFORM=$($OPENSSL version -p 2>/dev/null | sed 's/^platform: //')
     OSSL_BUILD_DATE=$($OPENSSL version -a 2>/dev/null | grep '^built' | sed -e 's/built on//' -e 's/: ... //' -e 's/: //' -e 's/ UTC//' -e 's/ +0000//' -e 's/.000000000//')

     # see #190, reverting logic: unless otherwise proved openssl has no dh bits
     case "$OSSL_VER_MAJOR.$OSSL_VER_MINOR" in
          1.0.2|1.1.0|1.1.1|3.0.0) HAS_DH_BITS=true ;;
     esac
     if [[ "$OSSL_NAME" =~ LibreSSL ]]; then
          [[ ${OSSL_VER//./} -ge 210 ]] && HAS_DH_BITS=true
          if "$SSL_NATIVE"; then
               outln
               pr_warning "LibreSSL in native ssl mode is not a good choice for testing INSECURE features!"
          fi
     fi

     initialize_engine

     openssl_location="$(type -p $OPENSSL)"
     [[ -n "$GIT_REL" ]] && \
          cwd="$(/bin/pwd)" || \
          cwd="$RUN_DIR"
     if [[ "$openssl_location" =~ $(/bin/pwd)/bin ]]; then
          OPENSSL_LOCATION="\$PWD/bin/$(basename "$openssl_location")"
     elif [[ "$openssl_location" =~ $cwd ]] && [[ "$cwd" != '.' ]]; then
          OPENSSL_LOCATION="${openssl_location%%$cwd}"
     else
         OPENSSL_LOCATION="$openssl_location"
     fi

     OSSL_CIPHERS_S=""
     HAS_SSL2=false
     HAS_SSL3=false
     HAS_TLS13=false
     HAS_X448=false
     HAS_X25519=false
     HAS_NO_SSL2=false
     HAS_NOSERVERNAME=false
     HAS_CIPHERSUITES=false
     HAS_COMP=false
     HAS_NO_COMP=false
     OSSL_SUPPORTED_CURVES=""
     HAS_PKEY=false
     HAS_PKUTIL=false
     HAS_ALPN=false
     HAS_NPN=false
     HAS_FALLBACK_SCSV=false
     HAS_PROXY=false
     HAS_XMPP=false
     HAS_POSTGRES=false
     HAS_MYSQL=false
     HAS_LMTP=false
     HAS_NNTP=false
     HAS_IRC=false
     HAS_CHACHA20=false
     HAS_AES128_GCM=false
     HAS_AES256_GCM=false
     HAS_ZLIB=false
     
     $OPENSSL ciphers -s 2>&1 | grep -aq "unknown option" || \
          OSSL_CIPHERS_S="-s"

     $OPENSSL s_client -ssl2 -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_SSL2=true

     $OPENSSL s_client -ssl3 -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_SSL3=true

     $OPENSSL s_client -tls1_3 -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_TLS13=true

     $OPENSSL genpkey -algorithm X448 -out - 2>&1 | grep -aq "not found" || \
          HAS_X448=true

     $OPENSSL genpkey -algorithm X25519 -out - 2>&1 | grep -aq "not found" || \
          HAS_X25519=true

     $OPENSSL s_client -no_ssl2 -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_NO_SSL2=true

     $OPENSSL s_client -noservername -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_NOSERVERNAME=true

     $OPENSSL s_client -ciphersuites -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_CIPHERSUITES=true

     $OPENSSL s_client -comp -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_COMP=true

     $OPENSSL s_client -no_comp -connect x 2>&1 | grep -aq "unknown option" || \
          HAS_NO_COMP=true

     OPENSSL_NR_CIPHERS=$(count_ciphers "$(actually_supported_ciphers 'ALL:COMPLEMENTOFALL' 'ALL')")

     for curve in "${curves_ossl[@]}"; do
          $OPENSSL s_client -curves $curve -connect x 2>&1 | grep -Eiaq "Error with command|unknown option"
          [[ $? -ne 0 ]] && OSSL_SUPPORTED_CURVES+=" $curve "
     done

     $OPENSSL pkey -help 2>&1 | grep -q Error || \
          HAS_PKEY=true

     $OPENSSL pkeyutl 2>&1 | grep -q Error || \
          HAS_PKUTIL=true

     $OPENSSL s_client -help 2>$s_client_has

     $OPENSSL s_client -starttls foo 2>$s_client_starttls_has

     grep -qw '\-alpn' $s_client_has && \
          HAS_ALPN=true

     grep -qw '\-nextprotoneg' $s_client_has && \
          HAS_NPN=true

     grep -qw '\-fallback_scsv' $s_client_has && \
          HAS_FALLBACK_SCSV=true

     grep -q '\-proxy' $s_client_has && \
          HAS_PROXY=true

     grep -q '\-xmpp' $s_client_has && \
          HAS_XMPP=true

     grep -q 'postgres' $s_client_starttls_has && \
          HAS_POSTGRES=true

     grep -q 'mysql' $s_client_starttls_has && \
          HAS_MYSQL=true

     grep -q 'lmtp' $s_client_starttls_has && \
          HAS_LMTP=true

     grep -q 'nntp' $s_client_starttls_has && \
          HAS_NNTP=true

     grep -q 'irc' $s_client_starttls_has && \
          HAS_IRC=true

     $OPENSSL enc -chacha20 -K "12345678901234567890123456789012" -iv "01000000123456789012345678901234" > /dev/null 2> /dev/null <<< "test"
     [[ $? -eq 0 ]] && HAS_CHACHA20=true

     $OPENSSL enc -aes-128-gcm -K 0123456789abcdef0123456789abcdef -iv 0123456789abcdef01234567  > /dev/null 2> /dev/null <<< "test"
     [[ $? -eq 0 ]] && HAS_AES128_GCM=true

     $OPENSSL enc -aes-256-gcm -K 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef -iv 0123456789abcdef01234567  > /dev/null 2> /dev/null <<< "test"
     [[ $? -eq 0 ]] && HAS_AES256_GCM=true

     [[ "$(echo -e "\x78\x9C\xAB\xCA\xC9\x4C\xE2\x02\x00\x06\x20\x01\xBC" | $OPENSSL zlib -d 2>/dev/null)" == zlib ]] && HAS_ZLIB=true

     if [[ "$OPENSSL_TIMEOUT" != "" ]]; then
          if type -p timeout >/dev/null 2>&1; then
               if ! "$do_mass_testing"; then
                    # there are different "timeout". Check whether --preserve-status is supported
                    if timeout --help 2>/dev/null | grep -q 'preserve-status'; then
                         OPENSSL="timeout --preserve-status $OPENSSL_TIMEOUT $OPENSSL"
                    else
                         OPENSSL="timeout $OPENSSL_TIMEOUT $OPENSSL"
                    fi
               fi
               MAX_OSSL_FAIL+=2
          else
               outln
               prln_warning " Necessary binary \"timeout\" not found."
               ignore_no_or_lame " Continue without timeout? " "yes"
               [[ $? -ne 0 ]] && exit $ERR_OSSLBIN
               unset OPENSSL_TIMEOUT
          fi
     fi

     return 0
}


check4openssl_oldfarts() {
     case "$OSSL_VER" in
          0.9.7*|0.9.6*|0.9.5*)
               # 0.9.5a was latest in 0.9.5 an released 2000/4/1, that'll NOT suffice for this test
               old_fart ;;
          0.9.8)
               case $OSSL_VER_APPENDIX in
                    a|b|c|d|e) old_fart;; # no SNI!
                    # other than that we leave this for MacOSX and FreeBSD but it's a pain and likely gives false negatives/positives
               esac
               ;;
     esac
     if [[ $OSSL_VER_MAJOR -lt 1 ]]; then ## mm: Patch for libressl
          prln_warning " Your \"$OPENSSL\" is way too old (<version 1.0) !"
          case $SYSTEM in
               *BSD|Darwin)
                    out " Please use binary provided in \$INSTALLDIR/bin/ or from ports/brew or compile from "
                    pr_url "github.com/PeterMosmans/openssl"; outln "."
                    fileout_insert_warning "too_old_openssl" "WARN" "Your $OPENSSL $OSSL_VER version is way too old. Please use binary provided in \$INSTALLDIR/bin/ or from ports/brew or compile from github.com/PeterMosmans/openssl ." ;;
               *)   out " Update openssl binaries or compile from "
                    pr_url "https://github.com/PeterMosmans/openssl"; outln "."
                    fileout_insert_warning "too_old_openssl" "WARN" "Update openssl binaries or compile from https://github.com/PeterMosmans/openssl .";;
          esac
          ignore_no_or_lame " Type \"yes\" to accept false negatives or positives" "yes"
          [[ $? -ne 0 ]] && exit $ERR_CLUELESS
     fi
     outln
}

# FreeBSD needs to have /dev/fd mounted. This is a friendly hint, see #258
check_bsd_mount() {
     if [[ "$(uname)" == FreeBSD ]]; then
          if ! mount | grep -q "^devfs"; then
               outln "you seem to run $PROG_NAME= in a jail. Hopefully you're did \"mount -t fdescfs fdesc /dev/fd\""
          elif mount | grep '/dev/fd' | grep -q fdescfs; then
               :
          else
               fatal "You need to mount fdescfs on FreeBSD: \"mount -t fdescfs fdesc /dev/fd\"" $ERR_OTHERCLIENT
          fi
     fi
}

# This sets the PRINTF command for writing into TCP sockets. It is needed because
# The shell builtin printf flushes the write buffer at every \n, ("\x0a") which
# in turn means a new TCP fragment. That causes a slight performance penalty and
# and some F5s to hiccup, see #1113. Unfortunately this can be used only with GNU's
# and OpenBSD's /usr/bin/printf -- FreeBSD + OS X can't do this. Thus here we need
# to pipe through dd or cat, see socksend() and socksend_clienthello(). An empty
# $PRINTF signals the bash internal printf which then uses cat as a stdout buffer.
# A better solution needs to follow.
#
choose_printf() {
     local p ptf

     ptf="$(type -aP printf)"
     if [[ -n "$ptf" ]]; then
          for p in $ptf; do
               if $p "\xc0\x14\xc0\xff\xee" | hexdump -C | grep -q 'c0 14 c0 ff ee'; then
                    PRINTF=$p
                    return 0
               fi
          done
     fi
     if type -t printf >/dev/null; then
          PRINTF=""
          return 0
     fi
     fatal "Neither external printf nor shell internal found. " $ERR_CLUELESS
}


help() {
     cat << EOF

     "$PROG_NAME [options] <URI>"    or    "$PROG_NAME <options>"


"$PROG_NAME <options>", where <options> is:

     --help                        what you're looking at
     -b, --banner                  displays banner + version of $PROG_NAME
     -v, --version                 same as previous
     -V, --local                   pretty print all local ciphers
     -V, --local <pattern>         which local ciphers with <pattern> are available? If pattern is not a number: word match

     <pattern>                     is always an ignore case word pattern of cipher hexcode or any other string in the name, kx or bits

"$PROG_NAME <URI>", where <URI> is:

     <URI>                         host|host:port|URL|URL:port   port 443 is default, URL can only contain HTTPS protocol)

"$PROG_NAME [options] <URI>", where [options] is:

     -t, --starttls <protocol>     Does a default run against a STARTTLS enabled <protocol,
                                   protocol is <ftp|smtp|lmtp|pop3|imap|xmpp|telnet|ldap|nntp|postgres|mysql>
     --xmpphost <to_domain>        For STARTTLS enabled XMPP it supplies the XML stream to-'' domain -- sometimes needed
     --mx <domain/host>            Tests MX records from high to low priority (STARTTLS, port 25)
     --file/-iL <fname>            Mass testing option: Reads one testssl.sh command line per line from <fname>.
                                   Implicitly turns on "--warnings batch". Can be combined with --serial or --parallel
                                   Text format 1: Comments via # allowed, EOF signals end of <fname>
                                   Text format 2: nmap output in greppable format (-oG), 1 port per line allowed
     --mode <serial|parallel>      Mass testing to be done serial (default) or parallel (--parallel is shortcut for the latter)

single check as <options>  ("$PROG_NAME URI" does everything except -E and -g):
     -e, --each-cipher             checks each local cipher remotely
     -E, --cipher-per-proto        checks those per protocol
     -s, --std, --standard         tests certain lists of cipher suites by strength
     -p, --protocols               checks TLS/SSL protocols (including SPDY/HTTP2)
     -g, --grease                  tests several server implementation bugs like GREASE and size limitations
     -S, --server-defaults         displays the server's default picks and certificate info
     -P, --server-preference       displays the server's picks: protocol+cipher
     -x, --single-cipher <pattern> tests matched <pattern> of ciphers
                                   (if <pattern> not a number: word match)
     -c, --client-simulation       test client simulations, see which client negotiates with cipher and protocol
     -h, --header, --headers       tests HSTS, HPKP, server/app banner, security headers, cookie, reverse proxy, IPv4 address

     -U, --vulnerable              tests all (of the following) vulnerabilities (if applicable)
     -H, --heartbleed              tests for Heartbleed vulnerability
     -I, --ccs, --ccs-injection    tests for CCS injection vulnerability
     -T, --ticketbleed             tests for Ticketbleed vulnerability in BigIP loadbalancers
     -BB, --robot                  tests for Return of Bleichenbacher's Oracle Threat (ROBOT) vulnerability
     -R, --renegotiation           tests for renegotiation vulnerabilities
     -C, --compression, --crime    tests for CRIME vulnerability (TLS compression issue)
     -B, --breach                  tests for BREACH vulnerability (HTTP compression issue)
     -O, --poodle                  tests for POODLE (SSL) vulnerability
     -Z, --tls-fallback            checks TLS_FALLBACK_SCSV mitigation
     -W, --sweet32                 tests 64 bit block ciphers (3DES, RC2 and IDEA): SWEET32 vulnerability
     -A, --beast                   tests for BEAST vulnerability
     -L, --lucky13                 tests for LUCKY13
     -F, --freak                   tests for FREAK vulnerability
     -J, --logjam                  tests for LOGJAM vulnerability
     -D, --drown                   tests for DROWN vulnerability
     -f, --pfs, --fs, --nsa        checks (perfect) forward secrecy settings
     -4, --rc4, --appelbaum        which RC4 ciphers are being offered?

tuning / connect options (most also can be preset via environment variables):
     --fast                        omits some checks: using openssl for all ciphers (-e), show only first preferred cipher.
     -9, --full                    includes tests for implementation bugs and cipher per protocol (could disappear)
     --bugs                        enables the "-bugs" option of s_client, needed e.g. for some buggy F5s
     --assume-http                 if protocol check fails it assumes HTTP protocol and enforces HTTP checks
     --ssl-native                  fallback to checks with OpenSSL where sockets are normally used
     --openssl <PATH>              use this openssl binary (default: look in \$PATH, \$RUN_DIR of $PROG_NAME)
     --proxy <host:port|auto>      (experimental) proxy connects via <host:port>, auto: values from \$env (\$http(s)_proxy)
     -6                            also use IPv6. Works only with supporting OpenSSL version and IPv6 connectivity
     --ip <ip>                     a) tests the supplied <ip> v4 or v6 address instead of resolving host(s) in URI
                                   b) arg "one" means: just test the first DNS returns (useful for multiple IPs)
     -n, --nodns <min|none>        if "none": do not try any DNS lookups, "min" queries A, AAAA and MX records
     --sneaky                      leave less traces in target logs: user agent, referer
     --ids-friendly                skips a few vulnerability checks which may cause IDSs to block the scanning IP
     --phone-out                   allow to contact external servers for CRL download and querying OCSP responder
     --add-ca <cafile>             path to <cafile> or a comma separated list of CA files enables test against additional CAs.

output options (can also be preset via environment variables):
     --warnings <batch|off|false>  "batch" doesn't ask for a confirmation, "off" or "false" skips connection warnings
     --openssl-timeout <seconds>   useful to avoid hangers. <seconds> to wait before openssl connect will be terminated
     --quiet                       don't output the banner. By doing this you acknowledge usage terms normally appearing in the banner
     --wide                        wide output for tests like RC4, BEAST. PFS also with hexcode, kx, strength, RFC name
     --show-each                   for wide outputs: display all ciphers tested -- not only succeeded ones
     --mapping <openssl|           openssl: use the OpenSSL cipher suite name as the primary name cipher suite name form (default)
                iana|rfc             -> use the IANA/(RFC) cipher suite name as the primary name cipher suite name form
                no-openssl|          -> don't display the OpenSSL cipher suite name, display IANA/(RFC) names only
                no-iana|no-rfc>      -> don't display the IANA/(RFC) cipher suite name, display OpenSSL names only
     --color <0|1|2|3>             0: no escape or other codes,  1: b/w escape codes,  2: color (default), 3: extra color (color all ciphers)
     --colorblind                  swap green and blue in the output
     --debug <0-6>                 1: screen output normal but keeps debug output in /tmp/.  2-6: see "grep -A 5 '^DEBUG=' testssl.sh"

file output options (can also be preset via environment variables)
     --log, --logging              logs stdout to '\${NODE}-p\${port}\${YYYYMMDD-HHMM}.log' in current working directory (cwd)
     --logfile|-oL <logfile>       logs stdout to 'dir/\${NODE}-p\${port}\${YYYYMMDD-HHMM}.log'. If 'logfile' is a dir or to a specified 'logfile'
     --json                        additional output of findings to flat JSON file '\${NODE}-p\${port}\${YYYYMMDD-HHMM}.json' in cwd
     --jsonfile|-oj <jsonfile>     additional output to the specified flat JSON file or directory, similar to --logfile
     --json-pretty                 additional JSON structured output of findings to a file '\${NODE}-p\${port}\${YYYYMMDD-HHMM}.json' in cwd
     --jsonfile-pretty|-oJ <jsonfile>  additional JSON structured output to the specified file or directory, similar to --logfile
     --csv                         additional output of findings to CSV file '\${NODE}-p\${port}\${YYYYMMDD-HHMM}.csv' in cwd or directory
     --csvfile|-oC <csvfile>       additional output as CSV to the specified file or directory, similar to --logfile
     --html                        additional output as HTML to file '\${NODE}-p\${port}\${YYYYMMDD-HHMM}.html'
     --htmlfile|-oH <htmlfile>     additional output as HTML to the specified file or directory, similar to --logfile
     --out(f,F)ile|-oa/-oA <fname> log to a LOG,JSON,CSV,HTML file (see nmap). -oA/-oa: pretty/flat JSON.
                                   "auto" uses '\${NODE}-p\${port}\${YYYYMMDD-HHMM}'. If fname if a dir uses 'dir/\${NODE}-p\${port}\${YYYYMMDD-HHMM}'
     --hints                       additional hints to findings
     --severity <severity>         severities with lower level will be filtered for CSV+JSON, possible values <LOW|MEDIUM|HIGH|CRITICAL>
     --append                      if (non-empty) <logfile>, <csvfile>, <jsonfile> or <htmlfile> exists, append to file. Omits any header
     --outprefix <fname_prefix>    before  '\${NODE}.' above prepend <fname_prefix>


Options requiring a value can also be called with '=' e.g. testssl.sh -t=smtp --wide --openssl=/usr/bin/openssl <URI>.
<URI> always needs to be the last parameter.

EOF
     # Set HTMLHEADER and JSONHEADER to false so that the cleanup() function won't
     # try to write footers to the HTML and JSON files.
     HTMLHEADER=false
     JSONHEADER=false
     #' Fix syntax highlight on sublime
     "$CHILD_MASS_TESTING" && kill -s USR1 $PPID
     exit $1
}

maketempf() {
     TEMPDIR=$(mktemp -d /tmp/testssl.XXXXXX) || exit $ERR_FCREATE
     TMPFILE=$TEMPDIR/tempfile.txt || exit $ERR_FCREATE
     if [[ "$DEBUG" -eq 0 ]]; then
          ERRFILE="/dev/null"
     else
          ERRFILE=$TEMPDIR/errorfile.txt || exit $ERR_FCREATE
     fi
     HOSTCERT=$TEMPDIR/host_certificate.pem
}

prepare_debug() {
     if [[ $DEBUG -ne 0 ]]; then
          cat >$TEMPDIR/environment.txt << EOF


CVS_REL: $CVS_REL
GIT_REL: $GIT_REL

PID: $$
commandline: "$CMDLINE"
bash version: ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}
status: ${BASH_VERSINFO[4]}
machine: ${BASH_VERSINFO[5]}
operating system: $SYSTEM $SYSTEMREV
os constraint: $SYSTEM2
shellopts: $SHELLOPTS
printf: $PRINTF
NO_ITALICS: $NO_ITALICS

$($OPENSSL version -a 2>/dev/null)
OSSL_VER_MAJOR: $OSSL_VER_MAJOR
OSSL_VER_MINOR: $OSSL_VER_MINOR
OSSL_VER_APPENDIX: $OSSL_VER_APPENDIX
OSSL_BUILD_DATE: $OSSL_BUILD_DATE
OSSL_VER_PLATFORM: $OSSL_VER_PLATFORM

OPENSSL_NR_CIPHERS: $OPENSSL_NR_CIPHERS
OPENSSL_CONF: $OPENSSL_CONF
OSSL_SUPPORTED_CURVES: $OSSL_SUPPORTED_CURVES

HAS_IPv6: $HAS_IPv6
HAS_SSL2: $HAS_SSL2
HAS_SSL3: $HAS_SSL3
HAS_TLS13: $HAS_TLS13
HAS_X448: $HAS_X448
HAS_X25519: $HAS_X25519
HAS_NO_SSL2: $HAS_NO_SSL2
HAS_SPDY: $HAS_SPDY
HAS_ALPN: $HAS_ALPN
HAS_FALLBACK_SCSV: $HAS_FALLBACK_SCSV
HAS_COMP: $HAS_COMP
HAS_NO_COMP: $HAS_NO_COMP
HAS_CIPHERSUITES: $HAS_CIPHERSUITES
HAS_PKEY: $HAS_PKEY
HAS_PKUTIL: $HAS_PKUTIL
HAS_PROXY: $HAS_PROXY
HAS_XMPP: $HAS_XMPP
HAS_POSTGRES: $HAS_POSTGRES
HAS_MYSQL: $HAS_MYSQL
HAS_LMTP: $HAS_LMTP
HAS_NNTP: $HAS_NNTP
HAS_IRC: $HAS_IRC

HAS_DIG: $HAS_DIG
HAS_HOST: $HAS_HOST
HAS_DRILL: $HAS_DRILL
HAS_NSLOOKUP: $HAS_NSLOOKUP
HAS_IDN: $HAS_IDN
HAS_IDN2: $HAS_IDN2
HAS_AVAHIRESOLVE: $HAS_AVAHIRESOLVE
HAS_DIG_NOIDNOUT: $HAS_DIG_NOIDNOUT

PATH: $PATH
PROG_NAME: $PROG_NAME
TESTSSL_INSTALL_DIR: $TESTSSL_INSTALL_DIR
RUN_DIR: $RUN_DIR
CIPHERS_BY_STRENGTH_FILE: $CIPHERS_BY_STRENGTH_FILE

CAPATH: $CAPATH
COLOR: $COLOR
COLORBLIND: $COLORBLIND
TERM_WIDTH: $TERM_WIDTH
INTERACTIVE: $INTERACTIVE
HAS_GNUDATE: $HAS_GNUDATE
HAS_FREEBSDDATE: $HAS_FREEBSDDATE
HAS_OPENBSDDATE: $HAS_OPENBSDDATE
HAS_SED_E: $HAS_SED_E

SHOW_EACH_C: $SHOW_EACH_C
SSL_NATIVE: $SSL_NATIVE
ASSUME_HTTP $ASSUME_HTTP
SNEAKY: $SNEAKY
OFFENSIVE: $OFFENSIVE
PHONE_OUT: $PHONE_OUT

DEBUG: $DEBUG

HSTS_MIN: $HSTS_MIN
HPKP_MIN: $HPKP_MIN
CLIENT_MIN_PFS: $CLIENT_MIN_PFS
DAYS2WARN1: $DAYS2WARN1
DAYS2WARN2: $DAYS2WARN2

HEADER_MAXSLEEP: $HEADER_MAXSLEEP
MAX_WAITSOCK: $MAX_WAITSOCK
HEARTBLEED_MAX_WAITSOCK: $HEARTBLEED_MAX_WAITSOCK
CCS_MAX_WAITSOCK: $CCS_MAX_WAITSOCK
USLEEP_SND $USLEEP_SND
USLEEP_REC $USLEEP_REC

EOF
          type -p locale &>/dev/null && locale >>$TEMPDIR/environment.txt || echo "locale doesn't exist" >>$TEMPDIR/environment.txt
          actually_supported_ciphers 'ALL:COMPLEMENTOFALL' 'ALL' "-V" &>$TEMPDIR/all_local_ciphers.txt
     fi
     # see also $TEMPDIR/s_client_has.txt from find_openssl_binary
}


prepare_arrays() {
     local hexc mac ossl_ciph
     local ossl_supported_tls="" ossl_supported_sslv2=""
     local -i i=0

     if [[ -e "$CIPHERS_BY_STRENGTH_FILE" ]]; then
          "$HAS_SSL2" && ossl_supported_sslv2="$($OPENSSL ciphers -ssl2 -V 'ALL:COMPLEMENTOFALL:@STRENGTH' 2>$ERRFILE)"
          if "$HAS_SSL2"; then
               ossl_supported_tls="$(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-tls1 -V")"
          else
               ossl_supported_tls="$(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL' "-V")"
          fi
          TLS13_OSSL_CIPHERS=""
          while read hexc n TLS_CIPHER_OSSL_NAME[i] TLS_CIPHER_RFC_NAME[i] TLS_CIPHER_SSLVERS[i] TLS_CIPHER_KX[i] TLS_CIPHER_AUTH[i] TLS_CIPHER_ENC[i] mac TLS_CIPHER_EXPORT[i]; do
               TLS_CIPHER_HEXCODE[i]="$hexc"
               TLS_CIPHER_OSSL_SUPPORTED[i]=false
               if [[ ${#hexc} -eq 9 ]]; then
                    # >= SSLv3 ciphers
                    if [[ $OSSL_VER_MAJOR -lt 1 ]]; then
                         [[ ":${ossl_supported_tls}:" =~ ":${TLS_CIPHER_OSSL_NAME[i]}:" ]] && TLS_CIPHER_OSSL_SUPPORTED[i]=true
                    else
                         ossl_ciph="$(awk '/'"$hexc"'/ { print $3 }' <<< "$ossl_supported_tls")"
                         if [[ -n "$ossl_ciph" ]]; then
                              TLS_CIPHER_OSSL_SUPPORTED[i]=true
                              [[ "$ossl_ciph" != ${TLS_CIPHER_OSSL_NAME[i]} ]] && TLS_CIPHER_OSSL_NAME[i]="$ossl_ciph"
                              [[ "${hexc:2:2}" == 13 ]] && TLS13_OSSL_CIPHERS+=":$ossl_ciph"
                         fi
                    fi
               elif [[ $OSSL_VER_MAJOR -lt 1 ]]; then
                    [[ ":${ossl_supported_sslv2}:" =~ ":${TLS_CIPHER_OSSL_NAME[i]}:" ]] && TLS_CIPHER_OSSL_SUPPORTED[i]=true
               else
                    [[ "$ossl_supported_sslv2" =~ $hexc ]] && TLS_CIPHER_OSSL_SUPPORTED[i]=true
               fi
               i+=1
          done < "$CIPHERS_BY_STRENGTH_FILE"
     fi
     TLS_NR_CIPHERS=i
     TLS13_OSSL_CIPHERS="${TLS13_OSSL_CIPHERS:1}"
}


mybanner() {
     local idtag
     local bb1 bb2 bb3

     "$QUIET" && return
     "$CHILD_MASS_TESTING" && return
     OPENSSL_NR_CIPHERS=$(count_ciphers "$(actually_supported_ciphers 'ALL:COMPLEMENTOFALL:@STRENGTH' 'ALL')")
     [[ -z "$GIT_REL" ]] && \
          idtag="$CVS_REL" || \
          idtag="$GIT_REL -- $CVS_REL_SHORT"
     bb1=$(cat <<EOF

###########################################################
    $PROG_NAME       $VERSION from 
EOF
)
     bb2=$(cat <<EOF

      This program is free software. Distribution and
             modification under GPLv2 permitted.
      USAGE w/o ANY WARRANTY. USE IT AT YOUR OWN RISK!

       Please file bugs @ 
EOF
)
     bb3=$(cat <<EOF

###########################################################
EOF
)
     pr_bold "$bb1"
     pr_boldurl "$SWURL"; outln
     if [[ -n "$idtag" ]]; then
          #FIXME: if we run it not off the git dir we miss the version tag.
          # at least we don't want to display empty brackets here...
          pr_bold "    ("
          pr_grey "$idtag"
          prln_bold ")"
     fi
     pr_bold "$bb2"
     pr_boldurl "https://testssl.sh/bugs/"; outln
     pr_bold "$bb3"
     outln "\n"
     outln " Using \"$($OPENSSL version 2>/dev/null)\" [~$OPENSSL_NR_CIPHERS ciphers]"
     out " on $HNAME:"
     outln "$OPENSSL_LOCATION"
     outln " (built: \"$OSSL_BUILD_DATE\", platform: \"$OSSL_VER_PLATFORM\")\n"
}

calc_scantime() {
          END_TIME=$(date +%s)
          SCAN_TIME=$(( END_TIME - START_TIME ))
}

cleanup() {
     # If parallel mass testing is being performed, then the child tests need
     # to be killed before $TEMPDIR is deleted. Otherwise, error messages
     # will be created if testssl.sh is stopped before all testing is complete.
     "$INTERACTIVE" && [[ $NR_PARALLEL_TESTS -gt 0 ]] && echo -en "\r                                                             \r" 1>&2
     while [[ $NEXT_PARALLEL_TEST_TO_FINISH -lt $NR_PARALLEL_TESTS ]]; do
          if [[ ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} -ne 0 ]] && \
             ps ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >/dev/null ; then
               kill ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >&2 2>/dev/null
               wait ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} 2>/dev/null    # make sure pid terminated, see wait(1p)
               get_next_message_testing_parallel_result "stopped"
          else
               # If a test had already completed, but its output wasn't yet processed,
               # then process it now.
               get_next_message_testing_parallel_result "completed"
          fi
          NEXT_PARALLEL_TEST_TO_FINISH+=1
     done
     if [[ "$DEBUG" -ge 1 ]]; then
          tmln_out
          tm_underline "DEBUG (level $DEBUG): see files in $TEMPDIR"
          tmln_out
     else
          [[ -d "$TEMPDIR" ]] && rm -rf "$TEMPDIR";
     fi
     outln
     "$SECTION_FOOTER_NEEDED" && fileout_section_footer true
     html_footer
     fileout_footer
     # debugging off, see above
     grep -q xtrace <<< "$SHELLOPTS" && ! "$DEBUG_ALLINONE" && exec 2>&42 42>&-
}

child_error() {
     cleanup
     exit $ERR_CHILD
}


# Program terminates prematurely, with error code
# arg1: string to print / to write to file
# arg2: global error code, see ERR_* above
# arg3: an optional hint (string)
#
fatal() {
     outln
     prln_magenta "Fatal error: $1" >&2
     [[ -n "$LOGFILE" ]] && prln_magenta "Fatal error: $1" >>$LOGFILE
     if [[ -n "$3" ]]; then
          outln "$3" >&2
          [[ -n "$LOGFILE" ]] && outln "$3" >>$LOGFILE
     fi
     fileout "scanProblem" "FATAL" "$1"
     exit $2
}

# This OTOH doesn't exit but puts a fatal error to the screen but continues with the next
# IP/hostname. It should only be used if a single IP/Hostname in a scan is not reachable.
# arg1: string to print / to write to file
#
ip_fatal() {
     outln
     prln_magenta "Fatal error: $1, proceeding with next IP (if any)" >&2
     [[ -n "$LOGFILE" ]] && prln_magenta "Fatal error: $1, proceeding with next IP (if any)" >>$LOGFILE
     outln
     fileout "scanProblem" "FATAL" "$1, proceeding with next IP (if any)"
     return 0
}

# This generic function outputs an error onto the screen and handles logging.
# arg1: string to print / to write to file, arg2 (optional): additional hint to write
#
generic_nonfatal() {
     prln_magenta "$1" >&2
     [[ -n $2 ]] && outln "$2"
     [[ -n "$LOGFILE" ]] && prln_magenta "$1" >>$LOGFILE && [[ -n $2 ]] && outln "$2" >>$LOGFILE
     outln
     fileout "scanProblem" "WARN" "$1"
     return 0
}

initialize_engine(){
     # for now only GOST engine
     grep -q '^# testssl config file' "$OPENSSL_CONF" 2>/dev/null && \
          return 0        # We have been here already
     if "$NO_ENGINE"; then
          # Avoid potential conflicts also -- manual hook, see #1117
          export OPENSSL_CONF=''
          return 1
     elif $OPENSSL engine gost -v 2>&1 | grep -Eq 'invalid command|no such engine'; then
          outln
          pr_warning "No engine or GOST support via engine with your $OPENSSL"; outln
          fileout_insert_warning "engine_problem" "WARN" "No engine or GOST support via engine with your $OPENSSL"
          export OPENSSL_CONF=''
          return 1
     elif ! $OPENSSL engine gost -vvvv -t -c 2>/dev/null >/dev/null; then
          # check for openssl 1.1.1 config -- not this may not be reliable. We only use this
          # to suppress the warning (confuses users), see #1119
          # https://github.com/openssl/openssl/commit/b524b808a1d1ba204dbdcbb42de4e3bddb3472ac
          if ! grep -q 'using the .include directive' /etc/ssl/openssl.cnf; then
                 outln
                 pr_warning "No engine or GOST support via engine with your $OPENSSL"; outln
          fi
          fileout_insert_warning "engine_problem" "WARN" "No engine or GOST support via engine with your $OPENSSL"
          # Avoid clashes of OpenSSL 1.1.1 config file with our openssl 1.0.2. This is for Debian 10
          export OPENSSL_CONF=''
          return 1
     else      # we have engine support
          if [[ -n "$OPENSSL_CONF" ]]; then
               prln_warning "For now I am providing the config file to have GOST support"
          else
               OPENSSL_CONF=$TEMPDIR/gost.conf
               # see https://www.mail-archive.com/openssl-users@openssl.org/msg65395.html
               cat >$OPENSSL_CONF << EOF
# testssl config file for openssl

openssl_conf            = openssl_def

[ openssl_def ]
engines                 = engine_section

[ engine_section ]
gost = gost_section

[ gost_section ]
engine_id = gost
default_algorithms = ALL
CRYPT_PARAMS = id-Gost28147-89-CryptoPro-A-ParamSet

EOF
               [[ $? -ne 0 ]] && exit $ERR_OSSLBIN
               export OPENSSL_CONF
          fi
     fi
     return 0
}

# arg1: text to display before "-->"
# arg2: arg needed to accept to continue
ignore_no_or_lame() {
     local a

     [[ "$WARNINGS" == off ]] && return 0
     [[ "$WARNINGS" == batch ]] && return 1
     tm_warning "$1 --> "
     read a
     if [[ "$2" == "$(toupper "$2")" ]]; then
          # all uppercase requested
          if [[ "$a" == "$2" ]];  then
               return 0
          else
               return 1
          fi
     elif [[ "$2" == "$(tolower "$a")" ]]; then
          # we normalize the word to continue
          return 0
     else
          return 1
     fi
}

# arg1: URI
parse_hn_port() {
     local tmp_port
     local node_tmp=""

     NODE="$1"
     NODE="${NODE/https\:\/\//}"        # strip "https"
     NODE="${NODE%%/*}"                 # strip trailing urlpath
     NODE="${NODE%%.}"                  # strip trailing "." if supplied
     if grep -q ':$' <<< "$NODE"; then
          if grep -wq http <<< "$NODE"; then
               fatal "\"http\" is not what you meant probably" $ERR_CMDLINE
          else
               fatal "\"$1\" is not a valid URI" $ERR_CMDLINE
          fi
     fi
     # Was an IPv6 address supplied like [AA:BB:CC::]:port ?
     if grep -q ']' <<< "$NODE"; then
          tmp_port=$(printf "$NODE" | sed 's/\[.*\]//' | sed 's/://')
          # determine v6 port, supposed it was supplied additionally
          if [[ -n "$tmp_port" ]]; then
               PORT=$tmp_port
               NODE=$(sed "s/:$PORT//" <<< "$NODE")
          fi
          NODE=$(sed -e 's/\[//' -e 's/\]//' <<< "$NODE")
     else
          # determine v4 port, supposed it was supplied additionally
          grep -q ':' <<< "$NODE" && \
               PORT=$(sed 's/^.*\://' <<< "$NODE") && NODE=$(sed 's/\:.*$//' <<< "$NODE")
     fi

     # We check for non-ASCII chars now. If there are some we'll try to convert it if IDN/IDN2 is installed
     # If not, we'll continue. Hoping later that dig can use it. If not the error handler will tell
     # Honestly we don't care whether it's IDN2008 or IDN2003 or Emoji domains as long as it works.
     # So we try to resolve anything supplied. If it can't  our resolver error handler takes care
     if [[ "$NODE" == *[![:ascii:]]* ]]; then
          if ! "$HAS_IDN2" && ! "$HAS_IDN"; then
               prln_warning " URI contains non-ASCII characters and libidn/libidn2 not available."
               outln " Trying to feed the resolver without converted \"$NODE\" ...\n"
               #ToDo: fileout is missing
               node_tmp="$NODE"
          elif "$HAS_IDN2"; then
               node_tmp="$(idn2 "$NODE" 2>/dev/null)"
          fi
          if "$HAS_IDN" && [[ -z "$node_tmp" ]]; then
               node_tmp="$(idn "$NODE" 2>/dev/null)"
          fi
          if [[ -z "$node_tmp" ]]; then
               prln_warning " URI contains non-ASCII characters and IDN conversion failed."
               outln " Trying to feed the resolver without converted \"$NODE\" ...\n"
               #ToDo: fileout is missing
               node_tmp="$NODE"
          fi
          NODE="$node_tmp"
     fi

     debugme echo $NODE:$PORT
     SNI="-servername $NODE"
     URL_PATH=$(sed 's/https:\/\///' <<< "$1" | sed 's/'"${NODE}"'//' | sed 's/.*'"${PORT}"'//')      # remove protocol and node part and port
     URL_PATH=$(sed 's/\/\//\//g' <<< "$URL_PATH")          # we rather want // -> /
     [[ -z "$URL_PATH" ]] && URL_PATH="/"
     debugme echo $URL_PATH
     return 0                                               # NODE, URL_PATH, PORT is set now
}


# args: string containing ip addresses
filter_ip6_address() {
     local a

     for a in "$@"; do
          if ! is_ipv6addr "$a"; then
               continue
          fi
          if "$HAS_SED_E"; then
               sed -E 's/^abcdeABCDEFf0123456789:]//g' <<< "$a" | sed -e '/^$/d' -e '/^;;/d'
          else
               sed -r 's/[^abcdefABCDEF0123456789:]//g' <<< "$a" | sed -e '/^$/d' -e '/^;;/d'
          fi
     done
}

filter_ip4_address() {
     local a

     for a in "$@"; do
          if ! is_ipv4addr "$a"; then
               continue
          fi
          if "$HAS_SED_E"; then
               sed -E 's/[^[:digit:].]//g' <<< "$a" | sed -e '/^$/d'
          else
               sed -r 's/[^[:digit:].]//g' <<< "$a" | sed -e '/^$/d'
          fi
     done
}

# For security testing sometimes we have local entries. Getent is BS under Linux for localhost: No network, no resolution
# arg1 is the entry we want to look up in the host file
get_local_aaaa() {
     local ip6=""
     local etchosts="/etc/hosts /c/Windows/System32/drivers/etc/hosts"

     [[ -z "$1" ]] && echo "" && return 1
     # Also multiple records should work fine
     ip6=$(grep -wih "$1" $etchosts 2>/dev/null | grep ':' | grep -Ev '^#|\.local' | grep -Ei "[[:space:]]$1" | awk '{ print $1 }')
     if is_ipv6addr "$ip6"; then
          echo "$ip6"
     else
          echo ""
     fi
}
get_local_a() {
     local ip4=""
     local etchosts="/etc/hosts /c/Windows/System32/drivers/etc/hosts"

     ip4=$(grep -wih "$1" $etchosts 2>/dev/null | grep -Ev ':|^#|\.local' | grep -Ei "[[:space:]]$1" | awk '{ print $1 }')
     if is_ipv4addr "$ip4"; then
          echo "$ip4"
     else
          echo ""
     fi
}

# Does a hard exit if no lookup binary is provided
# Checks for IDN capabilities also
#
check_resolver_bins() {
     type -p dig   &> /dev/null &&  HAS_DIG=true
     type -p host  &> /dev/null &&  HAS_HOST=true
     type -p drill &> /dev/null &&  HAS_DRILL=true
     type -p nslookup &> /dev/null && HAS_NSLOOKUP=true
     type -p avahi-resolve &>/dev/null && HAS_AVAHIRESOLVE=true
     type -p idn  &>/dev/null && HAS_IDN=true
     type -p idn2 &>/dev/null && HAS_IDN2=true

     if ! "$HAS_DIG" && ! "$HAS_HOST" && ! "$HAS_DRILL" && ! "$HAS_NSLOOKUP"; then
          fatal "Neither \"dig\", \"host\", \"drill\" or \"nslookup\" is present" $ERR_DNSBIN
     fi
     if "$HAS_DIG"; then
          if dig +noidnout -t a 2>&1 | grep -Eqv 'Invalid option: \+noidnout|IDN support not enabled'; then
               HAS_DIG_NOIDNOUT=true
          fi
     fi
     return 0
}

# arg1: a host name. Returned will be 0-n IPv4 addresses
# watch out: $1 can also be a cname! --> all checked
get_a_record() {
     local ip4=""
     local saved_openssl_conf="$OPENSSL_CONF"
     local noidnout=""

     [[ "$HAS_DIG_NOIDNOUT" ]] && noidnout="+noidnout"
     [[ "$NODNS" == none ]] && return 0      # if no DNS lookup was instructed, leave here
     if [[ "$1" == localhost ]]; then
          # This is a bit ugly but prevents from doing DNS lookups which could fail
          echo 127.0.0.1
          return 0
     fi
     if is_ipv4addr "$1"; then
          # This saves walking through this. Also it avoids hangs e.g. if you run docker locally without reachabale DNS
          echo $1
          return 0
     fi
     OPENSSL_CONF=""                         # see https://github.com/drwetter/testssl.sh/issues/134
     if [[ "$NODE" == *.local ]]; then
          if "$HAS_AVAHIRESOLVE"; then
               ip4=$(filter_ip4_address $(avahi-resolve -4 -n "$1" 2>/dev/null | awk '{ print $2 }'))
          elif "$HAS_DIG"; then
               ip4=$(filter_ip4_address $(dig @224.0.0.251 -p 5353 +short -t a +notcp "$1" 2>/dev/null | sed '/^;;/d'))
          else
               fatal "Local hostname given but no 'avahi-resolve' or 'dig' available." $ERR_DNSBIN
          fi
     fi
     if [[ -z "$ip4" ]] && "$HAS_DIG"; then
          ip4=$(filter_ip4_address $(dig +short +timeout=2 +tries=2 "$noidnout" -t a "$1" 2>/dev/null | awk '/^[0-9]/ { print $1 }'))
     fi
     if [[ -z "$ip4" ]] && "$HAS_HOST"; then
          ip4=$(filter_ip4_address $(host -t a "$1" 2>/dev/null | awk '/address/ { print $NF }'))
     fi
     if [[ -z "$ip4" ]] && "$HAS_DRILL"; then
          ip4=$(filter_ip4_address $(drill a "$1" | awk '/ANSWER SECTION/,/AUTHORITY SECTION/ { print $NF }' | awk '/^[0-9]/'))
     fi
     if [[ -z "$ip4" ]] && "$HAS_NSLOOKUP"; then
          ip4=$(filter_ip4_address $(strip_lf "$(nslookup -querytype=a "$1" 2>/dev/null | awk '/^Name/ { getline; print $NF }')"))
     fi
     OPENSSL_CONF="$saved_openssl_conf"      # see https://github.com/drwetter/testssl.sh/issues/134
     echo "$ip4"
}

# arg1: a host name. Returned will be 0-n IPv6 addresses
# watch out: $1 can also be a cname! --> all checked
get_aaaa_record() {
     local ip6=""
     local saved_openssl_conf="$OPENSSL_CONF"
     local noidnout=""

     [[ "$HAS_DIG_NOIDNOUT" ]] && noidnout="+noidnout"
     [[ "$NODNS" == none ]] && return 0      # if no DNS lookup was instructed, leave here
     OPENSSL_CONF=""                         # see https://github.com/drwetter/testssl.sh/issues/134
     if is_ipv6addr "$1"; then
          # This saves walking through this. Also it avoids hangs e.g. if you run docker locally without reachabale DNS
          echo "$1"
          return 0
     elif is_ipv4addr "$1"; then
          # we need also this here as get_aaaa_record is always called after get_a_record and we want to handle this at a low level
          return 0
     fi
     if [[ -z "$ip6" ]]; then
          if [[ "$NODE" == *.local ]]; then
               if "$HAS_AVAHIRESOLVE"; then
                    ip6=$(filter_ip6_address $(avahi-resolve -6 -n "$1" 2>/dev/null | awk '{ print $2 }'))
               elif "$HAS_DIG"; then
                    ip6=$(filter_ip6_address $(dig @ff02::fb -p 5353 -t aaaa +short +notcp "$NODE"))
               else
                    fatal "Local hostname given but no 'avahi-resolve' or 'dig' available." $ERR_DNSBIN
               fi
          elif "$HAS_DIG"; then
               ip6=$(filter_ip6_address $(dig +short +timeout=2 +tries=2 "$noidnout" -t aaaa "$1" 2>/dev/null | awk '/^[0-9]/ { print $1 }'))
          elif "$HAS_HOST"; then
               ip6=$(filter_ip6_address $(host -t aaaa "$1" | awk '/address/ { print $NF }'))
          elif "$HAS_DRILL"; then
               ip6=$(filter_ip6_address $(drill aaaa "$1" | awk '/ANSWER SECTION/,/AUTHORITY SECTION/ { print $NF }' | awk '/^[0-9]/'))
          elif "$HAS_NSLOOKUP"; then
               ip6=$(filter_ip6_address $(strip_lf "$(nslookup -type=aaaa "$1" 2>/dev/null | awk '/'"^${a}"'.*AAAA/ { print $NF }')"))
          fi
     fi
     OPENSSL_CONF="$saved_openssl_conf"      # see https://github.com/drwetter/testssl.sh/issues/134
     echo "$ip6"
}

# RFC6844: DNS Certification Authority Authorization (CAA) Resource Record
# arg1: domain to check for
get_caa_rr_record() {
     local raw_caa=""
     local -i len_caa_property
     local caa_property_name
     local caa_property_value
     local saved_openssl_conf="$OPENSSL_CONF"
     local all_caa=""
     local noidnout=""

     [[ "$HAS_DIG_NOIDNOUT" ]] && noidnout="+noidnout"

     [[ -n "$NODNS" ]] && return 0           # if minimum DNS lookup was instructed, leave here
     # if there's a type257 record there are two output formats here, mostly depending on age of distribution
     # roughly that's the difference between text and binary format
     # 1) 'google.com has CAA record 0 issue "symantec.com"'
     # 2) 'google.com has TYPE257 record \# 19 0005697373756573796D616E7465632E636F6D'
     # for dig +short the output always starts with '0 issue [..]' or '\# 19 [..]' so we normalize thereto to keep caa_flag, caa_property
     # caa_property then has key/value pairs, see https://tools.ietf.org/html/rfc6844#section-3
     OPENSSL_CONF=""
     if "$HAS_DIG"; then
          raw_caa="$(dig +short +timeout=3 +tries=3 "$noidnout" type257 "$1" 2>/dev/null | awk '{ print $1" "$2" "$3 }')"
          # empty if no CAA record
     elif "$HAS_DRILL"; then
          raw_caa="$(drill $1 type257 | awk '/'"^${1}"'.*CAA/ { print $5,$6,$7 }')"
     elif "$HAS_HOST"; then
          raw_caa="$(host -t type257 $1)"
          if grep -Ewvq "has no CAA|has no TYPE257" <<< "$raw_caa"; then
               raw_caa="$(sed -e 's/^.*has CAA record //' -e 's/^.*has TYPE257 record //' <<< "$raw_caa")"
          fi
     elif "$HAS_NSLOOKUP"; then
          raw_caa="$(strip_lf "$(nslookup -type=type257 $1 | grep -w rdata_257)")"
          if [[ -n "$raw_caa" ]]; then
               raw_caa="$(sed 's/^.*rdata_257 = //' <<< "$raw_caa")"
          fi
     else
          return 1
          # No dig, drill, host, or nslookup --> complaint was elsewhere already
     fi
     OPENSSL_CONF="$saved_openssl_conf"      # see https://github.com/drwetter/testssl.sh/issues/134
     debugme echo $raw_caa

     if [[ "$raw_caa" =~ \#\ [0-9][0-9] ]]; then
          # for posteo we get this binary format returned e.g. for old dig versions:
          # \# 19 0005697373756567656F74727573742E636F6D
          # \# 23 0009697373756577696C6467656F74727573742E636F6D
          # \# 34 0005696F6465666D61696C746F3A686F73746D617374657240706F73 74656F2E6465
          #  # len caaflag <more_see_below>                       @ p o s  t e o . d e
          while read hash len line ;do
               if [[ "${line:0:2}" == "00" ]]; then                             # probably the caa flag, always 00, so we don't keep this
                    len_caa_property=$(printf "%0d" "$((10#${line:2:2}))")      # get len and do type casting, for posteo we have 05 or 09 here as a string
                    len_caa_property=$((len_caa_property*2))                    # =>word! Now get name from 4th and value from 4th+len position...
                    line="${line/ /}"                                           # especially with iodefs there's a blank in the string which we just skip
                    caa_property_name="$(hex2ascii ${line:4:$len_caa_property})"
                    caa_property_value="$(hex2ascii "${line:$((4+len_caa_property)):100}")"
                    # echo "${caa_property_name}=${caa_property_value}"
                    all_caa+="${caa_property_name}=${caa_property_value}\n"
               else
                    outln "please report unknown CAA RR $line with flag  @ $NODE"
                    return 7
               fi
          done <<< "$raw_caa"
          sort <<< "$(safe_echo "$all_caa")"
          return 0
     elif grep -q '"' <<< "$raw_caa"; then
          raw_caa=${raw_caa//\"/}                           # strip all ". Now we should have flag, name, value
          #caa_property_name="$(awk '{ print $2 }' <<< "$raw_caa")"
          #caa_property_value="$(awk '{ print $3 }' <<< "$raw_caa")"
          safe_echo "$(sort <<< "$(awk '{ print $2"="$3 }' <<< "$raw_caa")")"
          return 0
     else
          # no caa record
          return 1
     fi

# to do:
#    4: check whether $1 is a CNAME and take this
     return 0
}

# watch out: $1 can also be a cname! --> all checked
get_mx_record() {
     local mx=""
     local saved_openssl_conf="$OPENSSL_CONF"
     local noidnout=""

     [[ "$HAS_DIG_NOIDNOUT" ]] && noidnout="+noidnout"
     OPENSSL_CONF=""                         # see https://github.com/drwetter/testssl.sh/issues/134
     # we need the last two columns here
     if "$HAS_HOST"; then
          mxs="$(host -t MX "$1" 2>/dev/null | awk '/is handled by/ { print $(NF-1), $NF }')"
     elif "$HAS_DIG"; then
          mxs="$(dig +short "$noidnout" -t MX "$1" 2>/dev/null | awk '/^[0-9]/ { print $1" "$2 }')"
     elif "$HAS_DRILL"; then
          mxs="$(drill mx $1 | awk '/IN[ \t]MX[ \t]+/ { print $(NF-1), $NF }')"
     elif "$HAS_NSLOOKUP"; then
          mxs="$(strip_lf "$(nslookup -type=MX "$1" 2>/dev/null | awk '/mail exchanger/ { print $(NF-1), $NF }')")"
     else
          # shouldn't reach this, as we checked in the top
          fatal "No dig, host, drill or nslookup" $ERR_DNSBIN
     fi
     OPENSSL_CONF="$saved_openssl_conf"
     echo "$mxs"
}


# set IPADDRs and IP46ADDRs
#
determine_ip_addresses() {
     local ip4=""
     local ip6=""

     ip4="$(get_a_record "$NODE")"
     ip6="$(get_aaaa_record "$NODE")"
     IP46ADDRs=$(newline_to_spaces "$ip4 $ip6")

     if [[ -n "$CMDLINE_IP" ]]; then
          # command line has supplied an IP address or "one"
          if [[ "$CMDLINE_IP" == one ]]; then
               # use first IPv6 or IPv4 address
               if "$HAS_IPv6" && [[ -n "$ip6" ]]; then
                    CMDLINE_IP="$(head -1 <<< "$ip6")"
               else
                    CMDLINE_IP="$(head -1 <<< "$ip4")"
               fi
          fi
          NODEIP="$CMDLINE_IP"
          if is_ipv4addr "$NODEIP"; then
               ip4="$NODEIP"
          elif is_ipv6addr "$NODEIP"; then
               ip6="$NODEIP"
          else
               fatal "couldn't identify supplied \"CMDLINE_IP\"" $ERR_DNSLOOKUP
          fi
     elif is_ipv4addr "$NODE"; then
          ip4="$NODE"                        # only an IPv4 address was supplied as an argument, no hostname
          SNI=""                             # override Server Name Indication as we test the IP only
     else
          ip4=$(get_local_a "$NODE")         # is there a local host entry?
          if [[ -z "$ip4" ]]; then           # empty: no (LOCAL_A is predefined as false)
               ip4=$(get_a_record "$NODE")
          else
               LOCAL_A=true                  # we have the ip4 from local host entry and need to signal this to testssl
          fi
          # same now for ipv6
          ip6=$(get_local_aaaa "$NODE")
          if [[ -z "$ip6" ]]; then
               ip6=$(get_aaaa_record "$NODE")
          else
               LOCAL_AAAA=true               # we have a local ipv6 entry and need to signal this to testssl
          fi
     fi

     # IPv6 only address
     if [[ -z "$ip4" ]]; then
          if "$HAS_IPv6"; then
               IPADDRs=$(newline_to_spaces "$ip6")
               IP46ADDRs="$IPADDRs"          # IP46ADDRs are the ones to display, IPADDRs the ones to test
          fi
     else
          if "$HAS_IPv6" && [[ -n "$ip6" ]]; then
               if is_ipv6addr "$CMDLINE_IP"; then
                    IPADDRs=$(newline_to_spaces "$ip6")
               else
                    IPADDRs=$(newline_to_spaces "$ip4 $ip6")
               fi
          else
               IPADDRs=$(newline_to_spaces "$ip4")
          fi
     fi
     if [[ -z "$IPADDRs" ]]; then
          if [[ -n "$ip6" ]]; then
               fatal "Only IPv6 address(es) for \"$NODE\" available, maybe add \"-6\" to $0" $ERR_DNSLOOKUP
          else
               fatal "No IPv4/IPv6 address(es) for \"$NODE\" available" $ERR_DNSLOOKUP
          fi
     fi
     return 0                                # IPADDR and IP46ADDR is set now
}

determine_rdns() {
     local saved_openssl_conf="$OPENSSL_CONF"
     local nodeip=""

     [[ -n "$NODNS" ]] && rDNS="(instructed to minimize DNS queries)" && return 0   # PTR records were not asked for
     local nodeip="$(tr -d '[]' <<< $NODEIP)"     # for DNS we do not need the square brackets of IPv6 addresses
     OPENSSL_CONF=""                              # see https://github.com/drwetter/testssl.sh/issues/134
     if [[ "$NODE" == *.local ]]; then
          if "$HAS_AVAHIRESOLVE"; then
               rDNS=$(avahi-resolve -a $nodeip 2>/dev/null | awk '{ print $2 }')
          elif "$HAS_DIG"; then
               rDNS=$(dig -x $nodeip @224.0.0.251 -p 5353 +notcp +noall +answer +short | awk '{ print $1 }')
          fi
     elif "$HAS_DIG"; then
          # 1+2 should suffice. It's a compromise for if e.g. network is down but we have a docker/localhost server
          rDNS=$(dig -x $nodeip +timeout=1 +tries=2 +noall +answer +short | awk '{ print $1 }')    # +short returns also CNAME, e.g. openssl.org
     elif "$HAS_HOST"; then
          rDNS=$(host -t PTR $nodeip 2>/dev/null | awk '/pointer/ { print $NF }')
     elif "$HAS_DRILL"; then
          rDNS=$(drill -x ptr $nodeip 2>/dev/null | awk '/ANSWER SECTION/ { getline; print $NF }')
     elif "$HAS_NSLOOKUP"; then
          rDNS=$(strip_lf "$(nslookup -type=PTR $nodeip 2>/dev/null | grep -v 'canonical name =' | grep 'name = ' | awk '{ print $NF }' | sed 's/\.$//')")
     fi
     OPENSSL_CONF="$saved_openssl_conf"      # see https://github.com/drwetter/testssl.sh/issues/134
     rDNS="$(echo $rDNS)"
     # remove chars which under weird circumstances can show up here
     rDNS=${rDNS// /}
     rDNS=${rDNS//;/}
     [[ -z "$rDNS" ]] && rDNS="--"
     return 0
}

# We need to get the IP address of the proxy so we can use it in fd_socket
#
check_proxy() {
     if [[ -n "$PROXY" ]]; then
          if ! "$HAS_PROXY"; then
               fatal "Your $OPENSSL is too old to support the \"-proxy\" option" $ERR_OSSLBIN
          fi
          if [[ "$PROXY" == auto ]]; then
               # Get $ENV https_proxy is the one we care about for connects
               PROXY="${https_proxy#*\/\/}"
               # Fallback:
               [[ -z "$PROXY" ]] && PROXY="${http_proxy#*\/\/}"
               [[ -z "$PROXY" ]] && fatal "you specified \"--proxy=auto\" but \"\$http(s)_proxy\" is empty" $ERR_CMDLINE
          fi
          # strip off http/https part if supplied:
          PROXY="${PROXY/http\:\/\//}"
          PROXY="${PROXY/https\:\/\//}"      # this shouldn't be needed
          PROXYNODE="${PROXY%:*}"
          PROXYPORT="${PROXY#*:}"
          is_number "$PROXYPORT" || fatal "Proxy port cannot be determined from \"$PROXY\"" $ERR_CMDLINE

          #if is_ipv4addr "$PROXYNODE" || is_ipv6addr "$PROXYNODE" ; then
          # IPv6 via openssl -proxy: that doesn't work. Sockets does
#FIXME: finish this with LibreSSL which supports an IPv6 proxy
          if is_ipv4addr "$PROXYNODE"; then
               PROXYIP="$PROXYNODE"
          else
               PROXYIP="$(get_a_record "$PROXYNODE" 2>/dev/null | grep -v alias | sed 's/^.*address //')"
               [[ -z "$PROXYIP" ]] && fatal "Proxy IP cannot be determined from \"$PROXYNODE\"" $ERR_CMDLINE
          fi
          PROXY="-proxy $PROXYIP:$PROXYPORT"
     fi
}


# this is only being called from determine_optimal_proto in order to check whether we have a server
# with client authentication, a server with no SSL session ID switched off
#
sclient_auth() {
     [[ $1 -eq 0 ]] && return 0                                            # no client auth (CLIENT_AUTH=false is preset globally)
     if [[ -n $(awk '/Master-Key: / { print $2 }' "$2") ]]; then           # connect succeeded
          if grep -q '^<<< .*CertificateRequest' "$2"; then                # CertificateRequest message in -msg
               CLIENT_AUTH=true
               return 0
          fi
          if [[ -z $(awk '/Session-ID: / { print $2 }' "$2") ]]; then      # probably no SSL session
               if [[ 2 -eq $(grep -c CERTIFICATE "$2") ]]; then            # do another sanity check to be sure
                    CLIENT_AUTH=false
                    NO_SSL_SESSIONID=true                                  # NO_SSL_SESSIONID is preset globally to false for all other cases
                    return 0
               fi
          fi
     fi
     # what's left now is: master key empty, handshake returned not successful, session ID empty --> not successful
     return 1
}

# Determine the best parameters to use with tls_sockets():
#   For TLSv1.3, determine what extension number to use for the key_share extension.
#   For TLSv1.2, determine what cipher list to send, since there are more than 128
#   TLSv1.2 ciphers and some servers fail if the ClientHello contains too many ciphers.
# If both TLSv1.3 and TLSv1.2 ClientHello messages result in failed connection attempts,
# then try to determine whether:
#   (1) This is an SSLv2-only server
#   (2) This server supports some protocol in SSLv3 - TLSv1.1, but cannot handle version negotiation.
#   (3) This is not a TLS/SSL enabled server.
# This information can be used by determine_optimal_proto() to help distinguish between a server
# that is not TLS/SSL enabled and one that is not compatible with the version of OpenSSL being used.
determine_optimal_sockets_params() {
     local -i ret1=1 ret2=1
     local i proto cipher_offered
     local all_failed=true

     # If a STARTTLS protocol is specified and $SSL_NATIVE is true, then skip this test, since 
     # $SSL_NATIVE may have been set to true as a result of tls_sockets() not supporting the STARTTLS
     # protocol.
     [[ -n "$STARTTLS_PROTOCOL" ]] && "$SSL_NATIVE" && return 0

     # NOTE: The following code is only needed as long as draft versions of TLSv1.3 prior to draft 23
     # are supported. It is used to determine whether a draft 23 or pre-draft 23 ClientHello should be
     # sent.
     KEY_SHARE_EXTN_NR="33"
     tls_sockets "04" "$TLS13_CIPHER" "" "00, 2b, 00, 0f, 0e, 03,04, 7f,1c, 7f,1b, 7f,1a, 7f,19, 7f,18, 7f,17"
     if [[ $? -eq 0 ]]; then
          add_tls_offered tls1_3 yes
          all_failed=false
     else
          KEY_SHARE_EXTN_NR="28"
          tls_sockets "04" "$TLS13_CIPHER" "" "00, 2b, 00, 0b, 0a, 7f,16, 7f,15, 7f,14, 7f,13, 7f,12"
          if [[ $? -eq 0 ]]; then
               add_tls_offered tls1_3 yes
               all_failed=false
          else
               add_tls_offered tls1_3 no
               KEY_SHARE_EXTN_NR="33"
          fi
     fi
     if ! "$all_failed"; then
          # Determine which version of TLS 1.3 was offered. For drafts 18-21 the
          # version appears in the ProtocolVersion field of the ServerHello. For
          # drafts 22-28 and the final TLS 1.3 the ProtocolVersion field contains
          # 0303 and the actual version appears in the supported_versions extension.
          if [[ "${TLS_SERVER_HELLO:8:3}" == 7F1 ]]; then
               add_tls_offered tls1_3_draft$(hex2dec "${TLS_SERVER_HELLO:10:2}") yes
          elif [[ "$TLS_SERVER_HELLO" =~ 002B00020304 ]]; then
               add_tls_offered tls1_3_rfc8446 yes
          else
               for i in 1C 1B 1A 19 18 17 16 15 14 13 12; do
                    if [[ "$TLS_SERVER_HELLO" =~ 002B00027F$i ]]; then
                         add_tls_offered tls1_3_draft$(hex2dec "$i") yes
                         break
                    fi
               done
          fi
     fi

     # Need to determine which set of ciphers is best to use with
     # a TLSv1.2 ClientHello since there are far more than 128 ciphers
     # that can be used.
     tls_sockets "03" "$TLS12_CIPHER"
     ret1=$?
     if [[ $ret1 -eq 0 ]] || [[ $ret1 -eq 2 ]]; then
          case $DETECTED_TLS_VERSION in
               0303)  add_tls_offered tls1_2 yes ;;
               0302)  add_tls_offered tls1_1 yes ;;
               0301)  add_tls_offered tls1 yes ;;
               0300)  add_tls_offered ssl3 yes ;;
          esac
          all_failed=false
     fi

     # Try again with a different, less common, set of cipher suites
     # see #807 and #806. If using these cipher suites results in a
     # successful connection, then change $TLS12_CIPHER to these
     # cipher suites so that later tests will use this list of cipher
     # suites.
     if [[ $ret1 -ne 0 ]]; then
          tls_sockets "03" "$TLS12_CIPHER_2ND_TRY"
          ret2=$?
          if [[ $ret2 -eq 0 ]]; then
               add_tls_offered tls1_2 yes
               TLS12_CIPHER="$TLS12_CIPHER_2ND_TRY"
               all_failed=false
          else
               add_tls_offered tls1_2 no
          fi
          if [[ $ret2 -eq 2 ]]; then
               case $DETECTED_TLS_VERSION in
                    0302)  add_tls_offered tls1_1 yes ;;
                    0301)  add_tls_offered tls1 yes ;;
                    0300)  add_tls_offered ssl3 yes ;;
               esac
               [[ $ret1 -ne 2 ]] && TLS12_CIPHER="$TLS12_CIPHER_2ND_TRY"
               all_failed=false
          fi
     fi
     if [[ $ret1 -eq 0 ]] || [[ $ret2 -eq 0 ]]; then
          cipher_offered="$(get_cipher "$TEMPDIR/$NODEIP.parse_tls_serverhello.txt")"
          if [[ "$cipher_offered" == TLS_* ]] || [[ "$cipher_offered" == SSL_* ]]; then
               cipher_offered="$(rfc2hexcode "$cipher_offered")"
          else
               cipher_offered="$(openssl2hexcode "$cipher_offered")"
          fi
          [[ ${#cipher_offered} -eq 9 ]] && TLS12_CIPHER_OFFERED="${cipher_offered:2:2},${cipher_offered:7:2}"
     fi

     if "$all_failed"; then
          # One of the following must be true:
          #   * This is not a TLS/SSL enabled server.
          #   * The server only supports SSLv2
          #   * The server does not handle version negotiation correctly.
          for proto in 01 00 02; do
               tls_sockets "$proto" "$TLS_CIPHER" "" "" "true"
               ret1=$?
               if [[ $ret1 -ne 0 ]]; then
                    case $proto in
                         02)  add_tls_offered tls1_1 no ;;
                         01)  add_tls_offered tls1 no ;;
                         00)  add_tls_offered ssl3 no ;;
                    esac
               fi
               if [[ $ret1 -eq 0 ]] || [[ $ret1 -eq 2 ]]; then
                    case $DETECTED_TLS_VERSION in
                         0302)  add_tls_offered tls1_1 yes ;;
                         0301)  add_tls_offered tls1 yes ;;
                         0300)  add_tls_offered ssl3 yes ;;
                    esac
                    OPTIMAL_SOCKETS_PROTO="$proto"
                    all_failed=false
                    break
               fi
          done
     fi
     if "$all_failed"; then
          sslv2_sockets
          [[ $? -eq 3 ]] && all_failed=false && add_tls_offered ssl2 yes
     fi
     ALL_FAILED_SOCKETS="$all_failed"
     return 0
}


# This function determines (STARTTLS_)OPTIMAL_PROTO. It is basically a workaround function as under certain
# circumstances a ClientHello without specifying a protocol will fail.
# Circumstances observed so far: 1.) IIS 6 and openssl 1.0.2 as opposed to 1.0.1  2.) starttls + dovecot imap.
# Independent on the server side it seems reasonable to to know upfront which protocol always works
#
# arg1: if empty: no STARTTLS, else: STARTTLS protocol
# The first try in the loop is empty as we prefer not to specify always a protocol if we can get along w/o it
#
determine_optimal_proto() {
     local all_failed=true
     local tmp=""
     local proto optimal_proto

     "$do_tls_sockets" && return 0

     >$ERRFILE
     if [[ -n "$1" ]]; then
          # STARTTLS workaround needed see https://github.com/drwetter/testssl.sh/issues/188 -- kind of odd
          for STARTTLS_OPTIMAL_PROTO in -tls1_2 -tls1 -ssl3 -tls1_1 -tls1_3 -ssl2; do
               case $STARTTLS_OPTIMAL_PROTO in
                    -tls1_3) "$HAS_TLS13" || continue ;;
                    -ssl3)   "$HAS_SSL3" || continue ;;
                    -ssl2)   "$HAS_SSL2" || continue ;;
                    *) ;;
               esac
               $OPENSSL s_client $(s_client_options "$STARTTLS_OPTIMAL_PROTO $BUGS -connect "$NODEIP:$PORT" $PROXY -msg -starttls $1" $SNI) </dev/null >$TMPFILE 2>>$ERRFILE
               if sclient_auth $? $TMPFILE; then
                    all_failed=false
                    add_tls_offered "${proto/-/}" yes
                    break
               fi
          done
          "$all_failed" && STARTTLS_OPTIMAL_PROTO=""
          optimal_proto="$STARTTLS_OPTIMAL_PROTO"
          debugme echo "STARTTLS_OPTIMAL_PROTO: $STARTTLS_OPTIMAL_PROTO"
     else
          # No STARTTLS
          for proto in '' -tls1_2 -tls1 -tls1_3 -ssl3 -tls1_1 -ssl2; do
               case $proto in
                    -tls1_3) "$HAS_TLS13" || continue ;;
                    -ssl3)   "$HAS_SSL3" || continue ;;
                    -ssl2)   "$HAS_SSL2" || continue ;;
                    *) ;;
               esac
               $OPENSSL s_client $(s_client_options "$proto $BUGS -connect "$NODEIP:$PORT" -msg $PROXY $SNI") </dev/null >$TMPFILE 2>>$ERRFILE
               if sclient_auth $? $TMPFILE; then
                    # we use the successful handshake at least to get one valid protocol supported -- it saves us time later
                    if [[ -z "$proto" ]]; then
                         # convert to openssl terminology
                         tmp=$(get_protocol $TMPFILE)
                         tmp=${tmp/\./_}
                         tmp=${tmp/v/}
                         tmp="$(tolower $tmp)"
                         add_tls_offered "${tmp}" yes
                         debugme echo "one proto determined: $tmp"
                         OPTIMAL_PROTO=""
                    else
                         add_tls_offered "${proto/-/}" yes
                         OPTIMAL_PROTO="$proto"
                    fi
                    all_failed=false
                    break
               fi
          done
          "$all_failed" && OPTIMAL_PROTO=""
          optimal_proto="$OPTIMAL_PROTO"

          debugme echo "OPTIMAL_PROTO: $OPTIMAL_PROTO"
     fi
     [[ "$optimal_proto" != -ssl2 ]]  && ! "$all_failed" && grep -q '^Server Temp Key' $TMPFILE && HAS_DH_BITS=true     # FIX #190
     if [[ "$(has_server_protocol "tls1_3")" -eq 0 ]] && [[ "$(has_server_protocol "tls1_2")" -ne 0 ]] &&
        [[ "$(has_server_protocol "tls1_1")" -ne 0 ]] && [[ "$(has_server_protocol "tls1")" -ne 0 ]] &&
        [[ "$(has_server_protocol "ssl3")" -ne 0 ]]; then
          TLS13_ONLY=true
     fi

     if [[ "$optimal_proto" == -ssl2 ]]; then
          prln_magenta "$NODEIP:$PORT appears to only support SSLv2."
          ignore_no_or_lame " Type \"yes\" to proceed and accept false negatives or positives" "yes"
          [[ $? -ne 0 ]] && exit $ERR_CLUELESS
     elif "$all_failed" && ! "$ALL_FAILED_SOCKETS"; then
          if ! "$HAS_TLS13" && "$TLS13_ONLY"; then
               pr_magenta " $NODE:$PORT appears to support TLS 1.3 ONLY. You better use --openssl=<path_to_openssl_supporting_TLS_1.3>"
               if ! "$OSSL_SHORTCUT" || [[ ! -x /usr/bin/openssl ]] || /usr/bin/openssl s_client -tls1_3 -connect x 2>&1 | grep -aq "unknown option"; then
                    outln
                    ignore_no_or_lame " Type \"yes\" to proceed and accept all scan problems" "yes"
                    [[ $? -ne 0 ]] && exit $ERR_CLUELESS
                    MAX_OSSL_FAIL=10
               else
                    # dirty hack but an idea for the future to be implemented upfront: Now we know, we'll better off
                    # with the OS supplied openssl binary. We need to inittialize variables / arrays again though.
                    # And the service detection can't be made up for now
                    outln ", \n proceeding with /usr/bin/openssl"
                    OPENSSL=/usr/bin/openssl
                    find_openssl_binary
                    prepare_arrays
               fi
          elif ! "$HAS_SSL3" && [[ "$(has_server_protocol "ssl3")" -eq 0 ]] && [[ "$(has_server_protocol "tls1_3")" -ne 0 ]] && \
               [[ "$(has_server_protocol "tls1_2")" -ne 0 ]] && [[ "$(has_server_protocol "tls1_1")" -ne 0 ]] &&
               [[ "$(has_server_protocol "tls1")" -ne 0 ]]; then
               prln_magenta " $NODE:$PORT appears to support SSLv3 ONLY. You better use --openssl=<path_to_openssl_supporting_SSL_3>"
               ignore_no_or_lame " Type \"yes\" to proceed and accept all scan problems" "yes"
               [[ $? -ne 0 ]] && exit $ERR_CLUELESS
               MAX_OSSL_FAIL=10
          else
               prln_bold " Your $OPENSSL cannot connect to $NODEIP:$PORT"
               ignore_no_or_lame " The results might look ok but they could be nonsense. Really proceed ? (\"yes\" to continue)" "yes"
               [[ $? -ne 0 ]] && exit $ERR_CLUELESS
          fi
     elif "$all_failed"; then
          outln
          if "$HAS_IPv6"; then
               pr_bold " Your $OPENSSL is not IPv6 aware, or $NODEIP:$PORT "
          else
               pr_bold " $NODEIP:$PORT "
          fi
          tmpfile_handle ${FUNCNAME[0]}.txt
          prln_bold "doesn't seem to be a TLS/SSL enabled server";
          ignore_no_or_lame " The results might look ok but they could be nonsense. Really proceed ? (\"yes\" to continue)" "yes"
          [[ $? -ne 0 ]] && exit $ERR_CLUELESS
     elif ! "$all_failed" && "$ALL_FAILED_SOCKETS" && ! "$SSL_NATIVE"; then
          # For some reason connecting with tls_sockets/sslv2_sockets didn't work, but connecting
          # with $OPENSSL s_client did.
          # FIXME: Should we include some sort of "please report" note here?
          prln_magenta " Testing with $NODE:$PORT only worked using $OPENSSL."
          prln_magenta " Test results may be somewhat better if the --ssl-native option is used."
          ignore_no_or_lame " Type \"yes\" to proceed and accept false negatives or positives" "yes"
          [[ $? -ne 0 ]] && exit $ERR_CLUELESS
     fi

     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0
}


# arg1 (optional): ftp smtp, lmtp, pop3, imap, xmpp, telnet, ldap, postgres, mysql, irc, nntp (maybe with trailing s)
#
determine_service() {
     local ua
     local protocol

     # Check if we can connect to $NODEIP:$PORT. Attention: This ALWAYS uses sockets. Thus timeouts for --ssl-=native do not apply
     if ! fd_socket 5; then
          if [[ -n "$PROXY" ]]; then
               fatal "You're sure $PROXYNODE:$PROXYPORT allows tunneling here? Can't connect to \"$NODEIP:$PORT\"" $ERR_CONNECT
          else
               if "$MULTIPLE_CHECKS"; then
                    ip_fatal "Couldn't connect to $NODEIP:$PORT"
                    return 1
               else
                    fatal "Can't connect to \"$NODEIP:$PORT\"\nMake sure a firewall is not between you and your scanning target!" $ERR_CONNECT
               fi
          fi
     fi
     close_socket

     outln
     if [[ -z "$1" ]]; then
          # no STARTTLS.
          determine_optimal_sockets_params
          determine_optimal_proto
          $SNEAKY && \
               ua="$UA_SNEAKY" || \
               ua="$UA_STD"
          GET_REQ11="GET $URL_PATH HTTP/1.1\r\nHost: $NODE\r\nUser-Agent: $ua\r\nAccept-Encoding: identity\r\nAccept: text/*\r\nConnection: Close\r\n\r\n"
          # returns always 0:
          service_detection $OPTIMAL_PROTO
     else # STARTTLS
          if [[ "$1" == postgres ]]; then
               protocol="postgres"
          else
               protocol=${1%s}     # strip trailing 's' in ftp(s), smtp(s), pop3(s), etc
          fi

          case "$protocol" in
               ftp|smtp|lmtp|pop3|imap|xmpp|telnet|ldap|postgres|mysql|nntp)
                    STARTTLS="-starttls $protocol"
                    if [[ "$protocol" == xmpp ]]; then
                         # for XMPP, openssl has a problem using -connect $NODEIP:$PORT. thus we use -connect $NODE:$PORT instead!
                         NODEIP="$NODE"
                         if [[ -n "$XMPP_HOST" ]]; then
                              if ! "$HAS_XMPP"; then
                                   fatal "Your $OPENSSL does not support the \"-xmpphost\" option" $ERR_OSSLBIN
                              fi
                              STARTTLS="$STARTTLS -xmpphost $XMPP_HOST"         # small hack -- instead of changing calls all over the place
                              # see http://xmpp.org/rfcs/rfc3920.html
                         else
                              if is_ipv4addr "$NODE"; then
                                   # XMPP needs a jabber domainname
                                   if [[ -n "$rDNS" ]]; then
                                        prln_warning " IP address doesn't work for XMPP, trying PTR record $rDNS"
                                        # remove trailing .
                                        NODE=${rDNS%%.}
                                        NODEIP=${rDNS%%.}
                                   else
                                        fatal "No DNS supplied and no PTR record available which I can try for XMPP" $ERR_DNSLOOKUP
                                   fi
                              fi
                         fi
                    elif [[ "$protocol" == postgres ]]; then
                         # Check if openssl version supports postgres.
                         if ! "$HAS_POSTGRES"; then
                              fatal "Your $OPENSSL does not support the \"-starttls postgres\" option" $ERR_OSSLBIN
                         fi
                    elif [[ "$protocol" == mysql ]]; then
                         # Check if openssl version supports mysql.
                         if ! "$HAS_MYSQL"; then
                              fatal "Your $OPENSSL does not support the \"-starttls mysql\" option" $ERR_OSSLBIN
                         fi
                    elif [[ "$protocol" == lmtp ]]; then
                         # Check if openssl version supports lmtp.
                         if ! "$HAS_LMTP"; then
                              fatal "Your $OPENSSL does not support the \"-starttls lmtp\" option" $ERR_OSSLBIN
                         fi
                    elif [[ "$protocol" == nntp ]]; then
                         # Check if openssl version supports lmtp.
                         if ! "$HAS_NNTP"; then
                              fatal "Your $OPENSSL does not support the \"-starttls nntp\" option" $ERR_OSSLBIN
                         fi
                    fi
                    determine_optimal_sockets_params
                    determine_optimal_proto "$1"

                    out " Service set:$CORRECT_SPACES            STARTTLS via "
                    out "$(toupper "$protocol")"
                    [[ "$protocol" == mysql ]] && out " (experimental)"
                    fileout "service" "INFO" "$protocol"
                    [[ -n "$XMPP_HOST" ]] && out " (XMPP domain=\'$XMPP_HOST\')"
                    outln
                    ;;
               *)   outln
                    fatal "momentarily only ftp, smtp, lmtp, pop3, imap, xmpp, telnet, ldap, nntp, postgres and mysql allowed" $ERR_CMDLINE
                    ;;
          esac
     fi
     tmpfile_handle ${FUNCNAME[0]}.txt
     return 0       # OPTIMAL_PROTO, GET_REQ*/HEAD_REQ* is set now
}


# Sets SERVER_SIZE_LIMIT_BUG to true or false, depending on whether we hit the 128 cipher limit.
# Return value is 0 unless we have a problem executing
#
determine_sizelimitbug() {
     # overflow_cipher must be some cipher that does not appear in TLS12_CIPHER.
     local overflow_cipher='C0,86'
     local -i nr_ciphers

     # For STARTTLS protcols not being implemented yet via sockets this is a bypass otherwise it won't be usable at all (e.g. LDAP)
     # Fixme: find out whether we can't skip this in general for STARTTLS
     [[ "$STARTTLS" =~ ldap ]] && return 0
     [[ "$STARTTLS" =~ irc ]] && return 0

     # Only with TLS 1.2 offered at the server side it is possible to hit this bug, in practise. Thus
     # we assume if TLS 1.2 is not supported, the server has no cipher size limit bug. It still may,
     # theoretically, but in a regular check with testssl.sh we won't hit this limit with lower protocols.
     # Upon calling this function we already know whether TLS 1.2 is supported. If TLS 1.2 is supported, we
     # send 129 ciphers (including 00FF) and check whether it works.

     if [[ 1 -eq $(has_server_protocol 03) ]]; then
          SERVER_SIZE_LIMIT_BUG=false
     else
          if [[ "$DEBUG" -ge 1 ]]; then
               nr_ciphers="$(tr ' ' '\n' <<< "${overflow_cipher}, $TLS12_CIPHER" | sed -e '/^$/d' | wc -l)"
               if [[ $nr_ciphers -ne 129 ]]; then
                    prln_warning "FIXME line $LINENO, ${FUNCNAME[0]} sending $nr_ciphers ciphers rather than 129."
               else
                    debugme echo "${FUNCNAME[0]} sending $nr_ciphers ciphers"
               fi
          fi
          tls_sockets 03 "${overflow_cipher}, ${TLS12_CIPHER}"
          if [[ $? -eq 0 ]]; then
               SERVER_SIZE_LIMIT_BUG=false
          else
               SERVER_SIZE_LIMIT_BUG=true
          fi
          debugme echo -e "\nSERVER_SIZE_LIMIT_BUG: $SERVER_SIZE_LIMIT_BUG"
     fi
     if "$SERVER_SIZE_LIMIT_BUG"; then
          out " Pre-test: "
          prln_svrty_medium "128 cipher limit bug"
          fileout "pre_128cipher" "MEDIUM" "128 cipher limit bug"
     else
          [[ "$DEBUG" -ge 1 ]] && outln " Pre-test: No 128 cipher limit bug"
          fileout "pre_128cipher" "INFO" "No 128 cipher limit bug"
     fi
     return 0
}


display_rdns_etc() {
     local ip further_ip_addrs=""
     local nodeip="$(tr -d '[]' <<< $NODEIP)"     # for displaying IPv6 addresses we don't need []

     if [[ -n "$PROXY" ]]; then
          out " Via Proxy:              $CORRECT_SPACES"
          outln "$PROXYIP:$PROXYPORT "
     fi
     if [[ $(count_words "$IP46ADDRs") -gt 1 ]]; then
          out " Further IP addresses:   $CORRECT_SPACES"
          for ip in $IP46ADDRs; do
               if [[ "$ip" == "$NODEIP" ]] || [[ "[$ip]" == "$NODEIP" ]]; then
                    continue
               else
                    further_ip_addrs+="$ip "
               fi
          done
          outln "$(out_row_aligned_max_width "$further_ip_addrs" "                         $CORRECT_SPACES" $TERM_WIDTH)"
     fi
     if "$LOCAL_A"; then
          outln " A record via:          $CORRECT_SPACES /etc/hosts "
     elif "$LOCAL_AAAA"; then
          outln " AAAA record via:       $CORRECT_SPACES /etc/hosts "
     elif  [[ -n "$CMDLINE_IP" ]]; then
          if is_ipv6addr $"$CMDLINE_IP"; then
               outln " AAAA record via:       $CORRECT_SPACES supplied IP \"$CMDLINE_IP\""
          else
               outln " A record via:          $CORRECT_SPACES supplied IP \"$CMDLINE_IP\""
          fi
     fi
     if [[ "$rDNS" =~ instructed ]]; then
          out "$(printf " %-23s " "rDNS ($nodeip):")"
          out "$rDNS"
     elif [[ -n "$rDNS" ]]; then
          out "$(printf " %-23s " "rDNS ($nodeip):")"
          out "$(out_row_aligned_max_width "$rDNS" "                         $CORRECT_SPACES" $TERM_WIDTH)"
     fi
}

datebanner() {
     local scan_time_f=""

     if [[ "$1" =~ Done ]] ; then
          scan_time_f="$(printf "%04ss" "$SCAN_TIME")"           # 4 digits because of windows
          pr_reverse "$1 $(date +%F) $(date +%T) [$scan_time_f] -->> $NODEIP:$PORT ($NODE) <<--"
     else
          pr_reverse "$1 $(date +%F) $(date +%T)        -->> $NODEIP:$PORT ($NODE) <<--"
     fi
     outln "\n"
     [[ "$1" =~ Start ]] && display_rdns_etc
}

# one line with char $1 over screen width $2
draw_line() {
     out "$(printf -- "$1"'%.s' $(eval "echo {1.."$(($2))"}"))"
}


run_mx_all_ips() {
     local mxs mx
     local mxport
     local -i ret=0
     local word=""

     STARTTLS_PROTOCOL="smtp"
     # test first higher priority servers
     mxs=$(get_mx_record "$1" | sort -n | sed -e 's/^.* //' -e 's/\.$//' | tr '\n' ' ')
     if [[ $CMDLINE_IP == one ]]; then
          word="as instructed one"                               # with highest priority
          mxs=${mxs%% *}
     else
          word="the only"
     fi
     mxport=${2:-25}
     if [[ -n "$LOGFILE" ]]; then
          prepare_logging
     else
          prepare_logging "${FNAME_PREFIX}mx-$1"
     fi
     if [[ -n "$mxs" ]] && [[ "$mxs" != ' ' ]]; then
          [[ $(count_words "$mxs") -gt 1 ]] && MULTIPLE_CHECKS=true
          if "$MULTIPLE_CHECKS"; then
               pr_bold "Testing all MX records (on port $mxport): "
          else
               pr_bold "Testing $word MX record (on port $mxport): "
          fi
          outln "$mxs"
          [[ $mxport == 465 ]] &&  STARTTLS_PROTOCOL=""          # no starttls for tcp 465, all other ports are starttls
          for mx in $mxs; do
               draw_line "-" $((TERM_WIDTH * 2 / 3))
               outln
               parse_hn_port "$mx:$mxport"
               determine_ip_addresses || continue
               if [[ $(count_words "$IPADDRs") -gt 1 ]]; then    # we have more than one ipv4 address to check
                    MULTIPLE_CHECKS=true
                    pr_bold "Testing all IPv4 addresses (port $PORT): "; outln "$IPADDRs"
                    for ip in $IPADDRs; do
                         NODEIP="$ip"
                         lets_roll "${STARTTLS_PROTOCOL}"
                    done
               else
                    NODEIP="$IPADDRs"
                    lets_roll "${STARTTLS_PROTOCOL}"
               fi
               ret=$(($? + ret))
          done
          draw_line "-" $((TERM_WIDTH * 2 / 3))
          outln
          pr_bold "Done testing all MX records (on port $mxport): "; outln "$mxs"
     else
          prln_bold " $1 has no MX records(s)"
     fi
     return $ret
}

# If run_mass_testing() is being used, then create the command line
# for the test based on the global command line (all elements of the
# command line provided to the parent, except the --file/-iL option) and the
# specific command line options for the test to be run. Each argument
# in the command line needs to be a separate element in an array in order
# to deal with word splitting within file names (see #702).
#
# If run_mass_testing_parallel() is being used, then in addition to the above,
# modify global command line for child tests so that if all (JSON, CSV, HTML)
# output is to go into a single file, each child will have its output placed in
# a separate, named file, so that the separate files can be concatenated
# together once they are complete to create the single file.
#
# If run_mass_testing() is being used, then "$1" is "serial". If
# run_mass_testing_parallel() is being used, then "$1" is "parallel XXXXXXXX"
# where XXXXXXXX is the number of the test being run.
#
create_mass_testing_cmdline() {
     local testing_type="$1"
     local cmd test_number
     local outfile_arg
     local -i nr_cmds=0 index=0
     local skip_next=false

     MASS_TESTING_CMDLINE=()
     [[ "$testing_type" =~ parallel ]] && read -r testing_type test_number <<< "$testing_type"

     # Start by adding the elements from the global command line to the command line for the
     # test. If run_mass_testing_parallel(), then modify the command line so that, when
     # required, each child process sends its test results to a separate file.  If a cmd
     # uses '=' for supplying a value we just skip next parameter (we don't use 'parse_opt_equal_sign' here)
     debugme echo "${CMDLINE_ARRAY[@]}"
     for cmd in "${CMDLINE_ARRAY[@]}"; do
          "$skip_next" && skip_next=false && index+=1 && continue
          if [[ "$cmd" =~ --file ]] || [[ "$cmd" =~ -iL ]]; then
               # Don't include the "--file[=...] or -iL argument in the child's command
               # line, but do include "--warnings=batch".
               MASS_TESTING_CMDLINE[nr_cmds]="--warnings=batch"
               nr_cmds+=1
               # next is the file itself, as no '=' was supplied
               [[ "$cmd" == --file ]] && skip_next=true
               [[ "$cmd" == -iL ]] && skip_next=true
          elif [[ "$testing_type" == serial ]]; then
               if "$JSONHEADER" && ( [[ "$cmd" =~ --jsonfile-pretty ]] || [[ "$cmd" =~ -oJ ]] ); then
                    >"$TEMPDIR/jsonfile_child.json"
                    MASS_TESTING_CMDLINE[nr_cmds]="--jsonfile-pretty=$TEMPDIR/jsonfile_child.json"
                    # next is the jsonfile itself, as no '=' was supplied
                    [[ "$cmd" == --jsonfile-pretty ]] && skip_next=true
                    [[ "$cmd" == -oJ ]] && skip_next=true
               elif "$JSONHEADER" && ( [[ "$cmd" =~ --jsonfile ]] || [[ "$cmd" =~ -oj ]] ); then
                    >"$TEMPDIR/jsonfile_child.json"
                    MASS_TESTING_CMDLINE[nr_cmds]="--jsonfile=$TEMPDIR/jsonfile_child.json"
                    # next is the jsonfile itself, as no '=' was supplied
                    [[ "$cmd" == --jsonfile ]] && skip_next=true
                    [[ "$cmd" == -oj ]] && skip_next=true
               elif "$JSONHEADER" && ( [[ "$cmd" =~ --outFile ]] || [[ "$cmd" =~ -oA ]] ); then
                    outfile_arg="$(parse_opt_equal_sign "$cmd" "${CMDLINE_ARRAY[index+1]}")"
                    >"$TEMPDIR/jsonfile_child.json"
                    MASS_TESTING_CMDLINE[nr_cmds]="-oJ=$TEMPDIR/jsonfile_child.json"
                    nr_cmds+=1
                    MASS_TESTING_CMDLINE[nr_cmds]="-oC=$outfile_arg.csv"
                    nr_cmds+=1
                    MASS_TESTING_CMDLINE[nr_cmds]="-oH=$outfile_arg.html"
                    # next is the filename itself, as no '=' was supplied
                    [[ "$cmd" == --outFile ]] && skip_next=true
                    [[ "$cmd" == -oA ]] && skip_next=true
               elif "$JSONHEADER" && ( [[ "$cmd" =~ --outfile ]] || [[ "$cmd" =~ -oa ]] ); then
                    outfile_arg="$(parse_opt_equal_sign "$cmd" "${CMDLINE_ARRAY[index+1]}")"
                    >"$TEMPDIR/jsonfile_child.json"
                    MASS_TESTING_CMDLINE[nr_cmds]="-oj=$TEMPDIR/jsonfile_child.json"
                    nr_cmds+=1
                    MASS_TESTING_CMDLINE[nr_cmds]="-oC=$outfile_arg.csv"
                    nr_cmds+=1
                    MASS_TESTING_CMDLINE[nr_cmds]="-oH=$outfile_arg.html"
                    # next is the filename itself, as no '=' was supplied
                    [[ "$cmd" == --outfile ]] && skip_next=true
                    [[ "$cmd" == -oa ]] && skip_next=true
               else
                    MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
               fi
               nr_cmds+=1
          else
               case "$cmd" in
                    --jsonfile|--jsonfile=*|-oj|-oj=*)
                         # If <jsonfile> is a file, then have provide a different
                         # file name to each child process. If <jsonfile> is a
                         # directory, then just pass it on to the child processes.
                         if "$JSONHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="--jsonfile=$TEMPDIR/jsonfile_${test_number}.json"
                              # next is the jsonfile itself, as no '=' was supplied
                              [[ "$cmd" == --jsonfile ]] && skip_next=true
                              [[ "$cmd" == -oj ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    --jsonfile-pretty|--jsonfile-pretty=*|-oJ|-oJ=*)
                         if "$JSONHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="--jsonfile-pretty=$TEMPDIR/jsonfile_${test_number}.json"
                              [[ "$cmd" == --jsonfile-pretty ]] && skip_next=true
                              [[ "$cmd" == -oJ ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    --csvfile|--csvfile=*|-oC|-oC=*)
                         if "$CSVHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="--csvfile=$TEMPDIR/csvfile_${test_number}.csv"
                              [[ "$cmd" == --csvfile ]] && skip_next=true
                              [[ "$cmd" == -oC ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    --htmlfile|--htmlfile=*|-oH|-oH=*)
                         if "$HTMLHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="--htmlfile=$TEMPDIR/htmlfile_${test_number}.html"
                              [[ "$cmd" == --htmlfile ]] && skip_next=true
                              [[ "$cmd" == -oH ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    --outfile|--outfile=*|-oa|-oa=*)
                         if "$JSONHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="-oj=$TEMPDIR/jsonfile_${test_number}.json"
                              nr_cmds+=1
                              MASS_TESTING_CMDLINE[nr_cmds]="-oC=$TEMPDIR/csvfile_${test_number}.csv"
                              nr_cmds+=1
                              MASS_TESTING_CMDLINE[nr_cmds]="-oH=$TEMPDIR/htmlfile_${test_number}.html"
                              # next is the filename itself, as no '=' was supplied
                              [[ "$cmd" == --outfile ]] && skip_next=true
                              [[ "$cmd" == -oa ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    --outFile|--outFile=*|-oA|-oA=*)
                         if "$JSONHEADER"; then
                              MASS_TESTING_CMDLINE[nr_cmds]="-oJ=$TEMPDIR/jsonfile_${test_number}.json"
                              nr_cmds+=1
                              MASS_TESTING_CMDLINE[nr_cmds]="-oC=$TEMPDIR/csvfile_${test_number}.csv"
                              nr_cmds+=1
                              MASS_TESTING_CMDLINE[nr_cmds]="-oH=$TEMPDIR/htmlfile_${test_number}.html"
                              # next is the filename itself, as no '=' was supplied
                              [[ "$cmd" == --outFile ]] && skip_next=true
                              [[ "$cmd" == -oA ]] && skip_next=true
                         else
                              MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         fi
                         ;;
                    *)
                         MASS_TESTING_CMDLINE[nr_cmds]="$cmd"
                         ;;
               esac
               nr_cmds+=1
          fi
          index+=1
     done

     # Now add the command line arguments for the specific test to the command line.
     # Skip the first argument sent to this function, since it specifies the type of testing being performed.
     shift
     while [[ $# -gt 0 ]]; do
          MASS_TESTING_CMDLINE[nr_cmds]="$1"
          nr_cmds+=1
          shift
     done

     return 0
}


ports2starttls() {
     local tcp_port=$1
     local ret=0

     # https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers
     case $tcp_port in
          21)       echo "-t ftp " ;;
          23)       echo "-t telnet " ;;
          119|433)  echo "-t nntp " ;;   # to come
          25|587)   echo "-t smtp " ;;
          110)      echo "-t pop3 " ;;
          143)      echo "-t imap " ;;
          389)      echo "-t ldap ";;
          3306)     echo "-t mysql " ;;
          5222)     echo "-t xmpp " ;;   # domain of jabber server maybe needed
          5432)     echo "-t postgres" ;;
          563)                ;;  # NNTPS
          636)                ;;  # LDAP
          1443|8443|443|981)  ;;  # HTTPS
          465)                ;;  # HTTPS | SMTP
          631)                ;;  # CUPS
          853)                ;;  # DNS over TLS
          995|993)            ;;  # POP3|IMAP
          3389)               ;;  # RDP
          *) ret=1            ;;  # we don't know this ports so we rather do not scan it
     esac
     return $ret
}

nmap_to_plain_file() {
     local target_fname=""
     local oneline=""
     local ip hostdontcare round_brackets ports_specs starttls
     local tmp port host_spec protocol dontcare dontcare1
     #FIXME: IPv6 is missing here

     # Ok, since we are here we are sure to have an nmap file. To avoid questions we make sure it's the right format too
     if [[ "$(head -1 "$FNAME")" =~ ( -oG )(.*) ]] || [[ "$(head -1 "$FNAME")" =~ ( -oA )(.*) ]] ; then
          # yes, greppable
          if [[ $(grep -c Status "$FNAME") -ge 1 ]]; then
               [[ $(grep -c  '\/open\/' "$FNAME")  -eq 0 ]] && \
                    fatal "Nmap file $FNAME should contain at least one open port" $ERR_FNAMEPARSE
          else
               fatal "strange, nmap grepable misses \"Status\"" -1
          fi
     else
          fatal "Nmap file $FNAME is not in grep(p)able format (-oG filename.g(n)map)" $ERR_FNAMEPARSE
     fi
     # strip extension and create output file *.txt in same folder
     target_fname="${FNAME%.*}.txt"
     > "${target_fname}"
     if [[ $? -ne 0 ]]; then
          # try to just create ${FNAME%.*}.txt in the same dir as the gnmap file failed.
          # backup is using one in $TEMPDIR
          target_fname="${target_fname##*\/}"     # strip path (Unix)
          target_fname="${target_fname##*\\}"     # strip path (Dos)
          target_fname="$TEMPDIR/$target_fname"
          > "${target_fname}" || fatal "Cannot create \"${target_fname}\"" $ERR_FCREATE
     fi

     # Line x:   "Host: AAA.BBB.CCC.DDD (<FQDN>) Status: Up"
     # Line x+1: "Host: AAA.BBB.CCC.DDD (<FQDN>) Ports: 443/open/tcp//https///"
     # (or):      Host: AAA.BBB.CCC.DDD (<FQDN>) Ports: 22/open/tcp//ssh//<banner>/, 25/open/tcp//smtp//<banner>/, 443/open/tcp//ssl|http//<banner>
     while read -r hostdontcare ip round_brackets tmp ports_specs; do
          [[ "$ports_specs" =~ "Status: "  ]] && continue             # we don't need this
          [[ "$ports_specs" =~ '/open/tcp/' ]] || continue            # no open tcp at all for this IP --> move
          host_spec="$ip"
          fqdn="${round_brackets/\(/}"
          fqdn="${fqdn/\)/}"
          if [[ -n "$fqdn" ]]; then
               tmp="$(get_a_record "$fqdn")"
               debugme echo "$tmp \?= $ip"
               if [[ "$tmp" == "$ip" ]]; then
                    host_spec="$fqdn"
               fi
          fi
          while read -r oneline; do
               # 25/open/tcp//smtp//<banner>/,
               [[ "$oneline" =~ '/open/tcp/' ]] || continue                # no open tcp for this port on this IP --> move on
               IFS=/ read -r port dontcare protocol dontcare1 <<< "$oneline"
               starttls="$(ports2starttls $port)"
               [[ $? -eq 1 ]] && continue                                  # nmap got a port but we don't know how to speak to
               [[ "$DEBUG" -ge 1 ]] && echo "${starttls}$host_spec:$port"
               echo "${starttls}${host_spec}:${port}" >>"$target_fname"
          done < <(tr ',' '\n' <<< "$ports_specs")
     done < "$FNAME"
     [[ "$DEBUG" -ge 1 ]] && echo

     [[ -s "$target_fname" ]] || \
          fatal "Couldn't find any open port in $FNAME" $ERR_FNAMEPARSE
     export FNAME=$target_fname
}

run_mass_testing() {
     local cmdline=""
     local first=true
     local gnmapadd=""
     local saved_fname="$FNAME"

     if [[ ! -r "$FNAME" ]] && "$IKNOW_FNAME"; then
          fatal "Can't read file \"$FNAME\"" $ERR_FNAMEPARSE
     fi

     if [[ "$(head -1 "$FNAME")" =~ (Nmap [4-8])(.*)( scan initiated )(.*) ]]; then
          gnmapadd="grep(p)able nmap "
          nmap_to_plain_file
     fi

     pr_reverse "====== Running in file batch mode with ${gnmapadd}file=\"$saved_fname\" ======"; outln "\n"
     while read -r cmdline; do
          cmdline="$(filter_input "$cmdline")"
          [[ -z "$cmdline" ]] && continue
          [[ "$cmdline" == EOF ]] && break
          # Create the command line for the child in the form of an array (see #702)
          create_mass_testing_cmdline "serial" $cmdline
          draw_line "=" $((TERM_WIDTH / 2)); outln;
          outln "$(create_cmd_line_string "$0" "${MASS_TESTING_CMDLINE[@]}")"
          # we call ourselves here. $do_mass_testing is the parent, $CHILD_MASS_TESTING... you figured
          if [[ -z "$(type -p "$0")" ]]; then
               CHILD_MASS_TESTING=true "$RUN_DIR/$PROG_NAME" "${MASS_TESTING_CMDLINE[@]}"
          else
               CHILD_MASS_TESTING=true "$0" "${MASS_TESTING_CMDLINE[@]}"
          fi
          if "$JSONHEADER" && [[ -s "$TEMPDIR/jsonfile_child.json" ]]; then
               # Need to ensure that a separator is only added if the test
               # produced some JSON output.
               "$first" || fileout_separator                         # this is needed for appended output, see #687
               first=false
               cat "$TEMPDIR/jsonfile_child.json" >> "$JSONFILE"
               FIRST_FINDING=false
          fi
     done < "${FNAME}"
     return $?
}

# This function is called when it has been determined that the next child
# process has completed or it has been stopped. If the child process completed,
# then this process prints the child process's output to the terminal and, if
# appropriate, adds any JSON, CSV, and HTML output it has created to the
# appropriate file. If the child process was stopped, then a message indicating
# that is printed, but the incomplete results are not used.
#
get_next_message_testing_parallel_result() {
     draw_line "=" $((TERM_WIDTH / 2)); outln;
     outln "${PARALLEL_TESTING_CMDLINE[NEXT_PARALLEL_TEST_TO_FINISH]}"
     if [[ "$1" == completed ]]; then
          cat "$TEMPDIR/term_output_$(printf "%08d" $NEXT_PARALLEL_TEST_TO_FINISH).log"
          if "$JSONHEADER" && [[ -s "$TEMPDIR/jsonfile_$(printf "%08d" $NEXT_PARALLEL_TEST_TO_FINISH).json" ]]; then
               # Need to ensure that a separator is only added if the test
               # produced some JSON output.
               "$FIRST_JSON_OUTPUT" || fileout_separator                     # this is needed for appended output, see #687
               FIRST_JSON_OUTPUT=false
               FIRST_FINDING=false
               cat "$TEMPDIR/jsonfile_$(printf "%08d" $NEXT_PARALLEL_TEST_TO_FINISH).json" >> "$JSONFILE"
          fi
          "$CSVHEADER" && cat "$TEMPDIR/csvfile_$(printf "%08d" $NEXT_PARALLEL_TEST_TO_FINISH).csv" >> "$CSVFILE"
          "$HTMLHEADER" && cat "$TEMPDIR/htmlfile_$(printf "%08d" $NEXT_PARALLEL_TEST_TO_FINISH).html" >> "$HTMLFILE"
     elif [[ "$1" == "stopped" ]]; then
          outln "\nTest was stopped before it completed.\n"
     else
          outln "\nTest timed out before it completed.\n"
     fi
}

#FIXME: not called/tested yet
run_mass_testing_parallel() {
     local cmdline=""
     local -i i nr_active_tests=0
     local -a -i start_time=()
     local -i curr_time wait_time
     local gnmapadd=""
     local saved_fname="$FNAME"

     if [[ ! -r "$FNAME" ]] && $IKNOW_FNAME; then
          fatal "Can't read file \"$FNAME\"" $ERR_FNAMEPARSE
     fi

     if [[ "$(head -1 "$FNAME")" =~ (Nmap [4-8])(.*)( scan initiated )(.*) ]]; then
          gnmapadd="grep(p)able nmap "
          nmap_to_plain_file
     fi

     pr_reverse "====== Running in file batch mode with ${gnmapadd}file=\"$saved_fname\" ======"; outln "\n"
     while read -r cmdline; do
          cmdline="$(filter_input "$cmdline")"
          [[ -z "$cmdline" ]] && continue
          [[ "$cmdline" == "EOF" ]] && break
          # Create the command line for the child in the form of an array (see #702)
          create_mass_testing_cmdline "parallel $(printf "%08d" $NR_PARALLEL_TESTS)" $cmdline

          # fileout() won't include the "service" information in the JSON file for the child process
          # if the JSON file doesn't already exist.
          "$JSONHEADER" && >"$TEMPDIR/jsonfile_$(printf "%08d" $NR_PARALLEL_TESTS).json"
          PARALLEL_TESTING_CMDLINE[NR_PARALLEL_TESTS]="$(create_cmd_line_string "$0" "${MASS_TESTING_CMDLINE[@]}")"
          if [[ -z "$(type -p "$0")" ]]; then
               CHILD_MASS_TESTING=true "$RUN_DIR/$PROG_NAME" "${MASS_TESTING_CMDLINE[@]}" > "$TEMPDIR/term_output_$(printf "%08d" $NR_PARALLEL_TESTS).log" 2>&1 &
          else
               CHILD_MASS_TESTING=true "$0" "${MASS_TESTING_CMDLINE[@]}" > "$TEMPDIR/term_output_$(printf "%08d" $NR_PARALLEL_TESTS).log" 2>&1 &
          fi
          PARALLEL_TESTING_PID[NR_PARALLEL_TESTS]=$!
          start_time[NR_PARALLEL_TESTS]=$(date +%s)
          if "$INTERACTIVE"; then
               echo -en "\r                                                             \r" 1>&2
               echo -n "Started test #$NR_PARALLEL_TESTS" 1>&2
               [[ $NEXT_PARALLEL_TEST_TO_FINISH -lt $NR_PARALLEL_TESTS ]] && \
                    echo -n " (waiting for test #$NEXT_PARALLEL_TEST_TO_FINISH to finish)" 1>&2
          fi
          NR_PARALLEL_TESTS+=1
          nr_active_tests+=1
          sleep $PARALLEL_SLEEP
          # Get the results of any completed tests
          while [[ $NEXT_PARALLEL_TEST_TO_FINISH -lt $NR_PARALLEL_TESTS ]]; do
               if [[ ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} -eq 0 ]]; then
                    "$INTERACTIVE" && echo -en "\r                                                             \r" 1>&2
                    get_next_message_testing_parallel_result "completed"
                    NEXT_PARALLEL_TEST_TO_FINISH+=1
               elif ! ps ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >/dev/null ; then
                    "$INTERACTIVE" && echo -en "\r                                                             \r" 1>&2
                    get_next_message_testing_parallel_result "completed"
                    NEXT_PARALLEL_TEST_TO_FINISH+=1
                    nr_active_tests=$nr_active_tests-1
               else
                    break
               fi
          done
          if [[ $nr_active_tests -ge $MAX_PARALLEL ]]; then
               curr_time=$(date +%s)
               while true; do
                    # Check to see if any test completed
                    for (( i=NEXT_PARALLEL_TEST_TO_FINISH; i < NR_PARALLEL_TESTS; i++ )); do
                         if [[ ${PARALLEL_TESTING_PID[i]} -ne 0 ]] && \
                            ! ps ${PARALLEL_TESTING_PID[i]} >/dev/null ; then
                              PARALLEL_TESTING_PID[i]=0
                              nr_active_tests=$nr_active_tests-1
                              break
                         fi
                    done
                    [[ $nr_active_tests -lt $MAX_PARALLEL ]] && break
                    if [[ $curr_time-${start_time[NEXT_PARALLEL_TEST_TO_FINISH]} -ge $MAX_WAIT_TEST ]]; then
                         # No test completed in the allocated time, so the first one to
                         # start will be killed.
                         kill ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >&2 2>/dev/null
                         wait ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} 2>/dev/null    # make sure pid terminated, see wait(1p)
                         "$INTERACTIVE" && echo -en "\r                                                             \r" 1>&2
                         get_next_message_testing_parallel_result "timeout"
                         NEXT_PARALLEL_TEST_TO_FINISH+=1
                         nr_active_tests=$nr_active_tests-1
                         break
                    fi
                    # Wake up to increment the counter every second (so that the counter
                    # appears to users as if it is operating smoothly), but check the
                    # status of the $MAX_PARALLEL active processes less often, since the
                    # ps command is expensive.
                    for (( i=0; i <= $((MAX_PARALLEL/5)); i++ )); do
                         wait_time=$((curr_time-start_time[NEXT_PARALLEL_TEST_TO_FINISH]))
                         [[ $wait_time -gt $MAX_WAIT_TEST ]] && wait_time=$MAX_WAIT_TEST
                         if "$INTERACTIVE"; then
                              echo -en "\r                                                             \r" 1>&2
                              echo -n "Waiting for test #$NEXT_PARALLEL_TEST_TO_FINISH to finish" 1>&2
                              if [[ $((MAX_WAIT_TEST-wait_time)) -le 60 ]]; then
                                   echo -n " ($((MAX_WAIT_TEST-wait_time)) seconds to timeout)" 1>&2
                              else
                                   echo -n " ($wait_time seconds)" 1>&2
                              fi
                         fi
                         [[ $wait_time -ge $MAX_WAIT_TEST ]] && break
                         sleep 1
                         curr_time=$(date +%s)
                    done
               done
          fi
     done < "$FNAME"

     # Wait for remaining tests to finish
     curr_time=$(date +%s)
     while [[ $NEXT_PARALLEL_TEST_TO_FINISH -lt $NR_PARALLEL_TESTS ]]; do
          if [[ ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} -eq 0 ]] || \
             ! ps ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >/dev/null ; then
               "$INTERACTIVE" && echo -en "\r                                                             \r" 1>&2
               get_next_message_testing_parallel_result "completed"
               NEXT_PARALLEL_TEST_TO_FINISH+=1
          elif [[ $curr_time-${start_time[NEXT_PARALLEL_TEST_TO_FINISH]} -ge $MAX_WAIT_TEST ]]; then
               kill ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} >&2 2>/dev/null
               wait ${PARALLEL_TESTING_PID[NEXT_PARALLEL_TEST_TO_FINISH]} 2>/dev/null    # make sure pid terminated, see wait(1p)
               "$INTERACTIVE" && echo -en "\r                                                             \r" 1>&2
               get_next_message_testing_parallel_result "timeout"
               NEXT_PARALLEL_TEST_TO_FINISH+=1
          else
               # Here it is okay to check process status every second, since the
               # status of only one process is being checked.
               if "$INTERACTIVE"; then
                    echo -en "\r                                                             \r" 1>&2
                    wait_time=$((curr_time-start_time[NEXT_PARALLEL_TEST_TO_FINISH]))
                    [[ $wait_time -gt $MAX_WAIT_TEST ]] && wait_time=$MAX_WAIT_TEST
                    echo -n "Waiting for test #$NEXT_PARALLEL_TEST_TO_FINISH to finish"          1>&2
                    if [[ $((MAX_WAIT_TEST-wait_time)) -le 60 ]]; then
                         echo -n " ($((MAX_WAIT_TEST-wait_time)) seconds to timeout)" 1>&2
                    else
                         echo -n " ($wait_time seconds)" 1>&2
                    fi
               fi
               sleep 1
               curr_time=$(date +%s)
          fi
     done
     return $?
}



# This initializes boolean global do_* variables. They keep track of what to do
# -- as the name insinuates
initialize_globals() {
     do_allciphers=false
     do_vulnerabilities=false
     do_beast=false
     do_lucky13=false
     do_breach=false
     do_ccs_injection=false
     do_ticketbleed=false
     do_robot=false
     do_cipher_per_proto=false
     do_crime=false
     do_freak=false
     do_logjam=false
     do_drown=false
     do_header=false
     do_heartbleed=false
     do_mx_all_ips=false
     do_mass_testing=false
     do_logging=false
     do_json=false
     do_pretty_json=false
     do_csv=false
     do_html=false
     do_pfs=false
     do_protocols=false
     do_rc4=false
     do_grease=false
     do_renego=false
     do_cipherlists=false
     do_server_defaults=false
     do_server_preference=false
     do_ssl_poodle=false
     do_sweet32=false
     do_tls_fallback_scsv=false
     do_cipher_match=false
     do_tls_sockets=false
     do_client_simulation=false
     do_display_only=false
     do_starttls=false
}


# Set default scanning options for the boolean global do_* variables.
set_scanning_defaults() {
     do_allciphers=true
     do_vulnerabilities=true
     do_beast=true
     do_lucky13=true
     do_breach=true
     do_heartbleed="$OFFENSIVE"
     do_ccs_injection="$OFFENSIVE"
     do_ticketbleed="$OFFENSIVE"
     do_robot="$OFFENSIVE"
     do_crime=true
     do_freak=true
     do_logjam=true
     do_drown=true
     do_ssl_poodle=true
     do_sweet32=true
     do_header=true
     do_pfs=true
     do_rc4=true
     do_protocols=true
     do_renego=true
     do_cipherlists=true
     do_server_defaults=true
     do_server_preference=true
     do_tls_fallback_scsv=true
     do_client_simulation=true
     if "$OFFENSIVE"; then
          VULN_COUNT=16
     else
          VULN_COUNT=12
     fi
}

# returns number of $do variables set = number of run_funcs() to perform
query_globals() {
     local gbl
     local true_nr=0

     for gbl in do_allciphers do_vulnerabilities do_beast do_lucky13 do_breach do_ccs_injection do_ticketbleed do_cipher_per_proto do_crime \
               do_freak do_logjam do_drown do_header do_heartbleed do_mx_all_ips do_pfs do_protocols do_rc4 do_grease do_robot do_renego \
               do_cipherlists do_server_defaults do_server_preference do_ssl_poodle do_tls_fallback_scsv \
               do_sweet32 do_client_simulation do_cipher_match do_tls_sockets do_mass_testing do_display_only; do
                    [[ "${!gbl}" == true ]] && let true_nr++
     done
     return $true_nr
}


debug_globals() {
     local gbl

     for gbl in do_allciphers do_vulnerabilities do_beast do_lucky13 do_breach do_ccs_injection do_ticketbleed do_cipher_per_proto do_crime \
               do_freak do_logjam do_drown do_header do_heartbleed do_mx_all_ips do_pfs do_protocols do_rc4 do_grease do_robot do_renego \
               do_cipherlists do_server_defaults do_server_preference do_ssl_poodle do_tls_fallback_scsv \
               do_sweet32 do_client_simulation do_cipher_match do_tls_sockets do_mass_testing do_display_only; do
          printf "%-22s = %s\n" $gbl "${!gbl}"
     done
     printf "%-22s : %s\n" URI: "$URI"
}


# arg1: either switch+value (=) or switch
# arg2: value (if no = provided)
parse_opt_equal_sign() {
     if [[ "$1" == *=* ]]; then
          echo ${1#*=}
          return 1  # = means we don't need to shift args!
     else
          echo "$2"
          return 0  # we need to shift
     fi
}

# Create the command line string for printing purposes
# See http://stackoverflow.com/questions/10835933/preserve-quotes-in-bash-arguments
create_cmd_line_string() {
     local arg
     local -a allargs=()
     local chars='[ !"#$&()*,;<>?\^`{|}]'

     while [[ $# -gt 0 ]]; do
          if [[ $1 == *\'* ]]; then
               arg=\""$1"\"
          elif [[ $1 == *$chars* ]]; then
               arg="'$1'"
          else
               arg="$1"
          fi
          allargs+=("$arg")    # ${allargs[@]} is to be used only for printing
          shift
     done
     printf '%s\n' "${allargs[*]}"
}

check_base_requirements() {
     local binary=''
     local whitelist=' hexdump grep awk sed '

     for binary in 'hexdump' 'dd' 'grep' 'awk' 'tr' 'sed' 'wc' 'date' 'cat' 'ps' 'kill' 'head' 'tail' 'dirname';  do
          if ! type -p "${binary}" &> /dev/null; then
               fatal "You need to install ${binary} for this program to work" $ERR_RESOURCE
          fi
          [[ ${whitelist} =~ \ ${binary}\  ]] && continue
          "${binary}" --help 2>&1 | grep -iq busybox
          if [[ $? -eq 0 ]]; then
               fatal "${binary} is from busybox. Please install a regular binary" $ERR_RESOURCE
          fi
     done
}

parse_cmd_line() {
     local outfile_arg=""
     local cipher_mapping
     local -i subret=0

     CMDLINE="$(create_cmd_line_string "${CMDLINE_ARRAY[@]}")"

     # Show usage if no options were specified
     [[ -z "$1" ]] && help 0
     # Set defaults if only an URI was specified, maybe ToDo: use "="-option, then: ${i#*=} i.e. substring removal
     [[ "$#" -eq 1 ]] && set_scanning_defaults

     while [[ $# -gt 0 ]]; do
          case $1 in
               --help)
                    help 0
                    ;;
               -b|--banner|-v|--version)
                    maketempf
                    get_install_dir
                    find_openssl_binary
                    prepare_debug
                    mybanner
                    exit $ALLOK
                   ;;
               --mx)
                    do_mx_all_ips=true
                    PORT=25
                    ;;
               --mx465)                      # doesn't work with major ISPs
                    do_mx_all_ips=true
                    PORT=465
                    ;;
               --mx587)                      # doesn't work with major ISPs
                    do_mx_all_ips=true
                    PORT=587
                    ;;
               --ip|--ip=*)
                    CMDLINE_IP="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    if [[ "$CMDLINE_IP" == proxy ]]; then
                         DNS_VIA_PROXY=true
                         unset CMDLINE_IP
                    fi
                    # normalize any IPv6 address
                    CMDLINE_IP="${CMDLINE_IP//[/}"      # fix vim syntax highlighting "]
                    CMDLINE_IP="${CMDLINE_IP//]/}"
                    ;;
               -n|--nodns|-n=*|--nodns=*)
                    NODNS="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    if [[ "$NODNS" != none ]] && [[ "$NODNS" != min ]]; then
                         fatal "Value for nodns switch can be either \"min\" or \"none\"" $ERR_CMDLINE
                    fi
                    ;;
               -V|-V=*|--local|--local=*)    # attention, this could have a value or not!
                    do_display_only=true
                    PATTERN2SHOW="$(parse_opt_equal_sign "$1" "$2")"
                    subret=$?
                    if [[ "$PATTERN2SHOW" == -* ]]; then
                         unset PATTERN2SHOW  # we hit the next command ==> not our value
                    else                     # it was ours, point to next arg
                         [[ $subret -eq 0 ]] && shift
                    fi
                    ;;
               -x|-x=*|--single[-_]cipher|--single[-_]cipher=*)
                    do_cipher_match=true
                    single_cipher=$(parse_opt_equal_sign "$1" "$2")
                    [[ $? -eq 0 ]] && shift
                    ;;
               -t|-t=*|--starttls|--starttls=*)
                    do_starttls=true
                    STARTTLS_PROTOCOL="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    case $STARTTLS_PROTOCOL in
                         ftp|smtp|lmtp|pop3|imap|xmpp|telnet|ldap|irc|nntp|postgres|mysql) ;;
                         ftps|smtps|lmtps|pop3s|imaps|xmpps|telnets|ldaps|ircs|nntps|mysqls) ;;
                         *)   tmln_magenta "\nunrecognized STARTTLS protocol \"$1\", see help" 1>&2
                              help 1 ;;
                    esac
                    ;;
               --xmpphost|--xmpphost=*)
                    XMPP_HOST=$(parse_opt_equal_sign "$1" "$2")
                    [[ $? -eq 0 ]] && shift
                    ;;
               -e|--each-cipher)
                    do_allciphers=true
                    ;;
               -E|--cipher-per-proto|--cipher_per_proto)
                    do_cipher_per_proto=true
                    ;;
               -p|--protocols)
                    do_protocols=true
                    ;;
               -s|--std|--standard)
                    do_cipherlists=true
                    ;;
               -S|--server[-_]defaults)
                    do_server_defaults=true
                    ;;
               -P|--server[_-]preference|--preference)
                    do_server_preference=true
                    ;;
               -h|--header|--headers)
                    do_header=true
                    ;;
               -c|--client-simulation)
                    do_client_simulation=true
                    ;;
               -U|--vulnerable|--vulnerabilities)
                    do_vulnerabilities=true
                    do_heartbleed="$OFFENSIVE"
                    do_ccs_injection="$OFFENSIVE"
                    do_ticketbleed="$OFFENSIVE"
                    do_robot="$OFFENSIVE"
                    do_renego=true
                    do_crime=true
                    do_breach=true
                    do_ssl_poodle=true
                    do_tls_fallback_scsv=true
                    do_sweet32=true
                    do_freak=true
                    do_drown=true
                    do_logjam=true
                    do_beast=true
                    do_lucky13=true
                    do_rc4=true
                    if "$OFFENSIVE"; then
                         VULN_COUNT=16
                    else
                         VULN_COUNT=12
                    fi
                    ;;
               --ids-friendly)
                    OFFENSIVE=false
                    ;;
               -H|--heartbleed)
                    do_heartbleed=true
                    let "VULN_COUNT++"
                    ;;
               -I|--ccs|--ccs[-_]injection)
                    do_ccs_injection=true
                    let "VULN_COUNT++"
                    ;;
               -T|--ticketbleed)
                    do_ticketbleed=true
                    let "VULN_COUNT++"
                    ;;
               -BB|--robot)
                    do_robot=true
                    ;;
               -R|--renegotiation)
                    do_renego=true
                    let "VULN_COUNT++"
                    ;;
               -C|--compression|--crime)
                    do_crime=true
                    let "VULN_COUNT++"
                    ;;
               -B|--breach)
                    do_breach=true
                    let "VULN_COUNT++"
                    ;;
               -O|--poodle)
                    do_ssl_poodle=true
                    do_tls_fallback_scsv=true
                    let "VULN_COUNT++"
                    ;;
               -Z|--tls[_-]fallback|tls[_-]fallback[_-]scs)
                    do_tls_fallback_scsv=true
                    let "VULN_COUNT++"
                    ;;
               -W|--sweet32)
                    do_sweet32=true
                    let "VULN_COUNT++"
                    ;;
               -F|--freak)
                    do_freak=true
                    let "VULN_COUNT++"
                    ;;
               -D|--drown)
                    do_drown=true
                    let "VULN_COUNT++"
                    ;;
               -J|--logjam)
                    do_logjam=true
                    let "VULN_COUNT++"
                    ;;
               -A|--beast)
                    do_beast=true
                    let "VULN_COUNT++"
                    ;;
               -L|--lucky13)
                    do_lucky13=true
                    let "VULN_COUNT++"
                    ;;
               -4|--rc4|--appelbaum)
                    do_rc4=true
                    let "VULN_COUNT++"
                    ;;
               -f|--pfs|--fs|--nsa)
                    do_pfs=true
                    ;;
               -g|--grease)
                    do_grease=true
                    ;;
               -9|--full)
                    set_scanning_defaults
                    do_allciphers=false
                    do_cipher_per_proto=true
                    do_grease=true
                    ;;
               --add-ca|--add-CA|--add-ca=*|--add-CA=*)
                    ADDITIONAL_CA_FILES="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    ;;
               --devel) ### this development feature will soon disappear
                    # arg1: SSL/TLS protocol (SSLv2=22)
                    # arg2: list of cipher suites / hostname/ip
                    # arg3: hostname/ip
                    HEX_CIPHER="$TLS12_CIPHER"
                    # DEBUG=3  ./testssl.sh --devel 04 "13,02, 13,01" google.com                               --> TLS 1.3
                    # DEBUG=3  ./testssl.sh --devel 03 "cc, 13, c0, 13" google.de                              --> TLS 1.2, old CHACHA/POLY
                    # DEBUG=3  ./testssl.sh --devel 03 "cc,a8, cc,a9, cc,aa, cc,ab, cc,ac" blog.cloudflare.com -->          new CHACHA/POLY
                    # DEBUG=3  ./testssl.sh --devel 01 yandex.ru                     --> TLS 1.0
                    # DEBUG=3  ./testssl.sh --devel 00 <host which supports SSLv3>
                    # DEBUG=3  ./testssl.sh --devel 22 <host which still supports SSLv2>
                    TLS_LOW_BYTE="$2";
                    if [[ $# -eq 4 ]]; then  # protocol AND ciphers specified
                         HEX_CIPHER="$3"
                         shift
                    fi
                    shift
                    do_tls_sockets=true
                    outln "\nTLS_LOW_BYTE, HEX_CIPHER: \"${TLS_LOW_BYTE}\", \"${HEX_CIPHER}\""
                    ;;
               --wide)
                    WIDE=true
                    ;;
               --assuming[_-]http|--assume[-_]http)
                    ASSUME_HTTP=true
                    ;;
               --sneaky)
                    SNEAKY=true
                    ;;
               -q|--quiet)
                    QUIET=true
                    ;;
               --file|--file=*|-iL|-iL=*)
                    # no shift here as otherwise URI is empty and it bails out
                    FNAME="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    IKNOW_FNAME=true
                    WARNINGS=batch           # set this implicitly!
                    do_mass_testing=true
                    ;;
               --mode|--mode=*)
                    MASS_TESTING_MODE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    case "$MASS_TESTING_MODE" in
                         serial|parallel) ;;
                         *)   tmln_magenta "\nmass testing mode can be either \"serial\" or \"parallel\""
                              help 1
                    esac
                    ;;
               --serial)
                    MASS_TESTING_MODE=serial
                    ;;
               --parallel)
                    MASS_TESTING_MODE=parallel
                    ;;
               --warnings|--warnings=*)
                    WARNINGS=$(parse_opt_equal_sign "$1" "$2")
                    [[ $? -eq 0 ]] && shift
                    case "$WARNINGS" in
                         batch|off) ;;
                         *)   tmln_magenta "\nwarnings can be either \"batch\", or \"off\""
                              help 1
                    esac
                    ;;
               --show[-_]each)
                    SHOW_EACH_C=true
                    ;;
               --fast)
                    FAST=true
                    ;;
               --bugs)
                    BUGS="-bugs"
                    ;;
               --debug|--debug=*)
                    DEBUG=$(parse_opt_equal_sign "$1" "$2")
                    [[ $? -eq 0 ]] && shift
                    case $DEBUG in
                         [0-6]) ;;
                         *)   tmln_magenta_term "\nunrecognized debug value \"$1\", must be between 0..6" 1>&2
                              help 1
                    esac
                    ;;
               --color|--color=*)
                    COLOR="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    case $COLOR in
                         [0-3]) ;;
                         *)   COLOR=2
                              tmln_magenta "\nunrecognized color: \"$1\", must be between 0..3" 1>&2
                              help 1
                    esac
                    ;;
               --colorblind)
                    COLORBLIND=true
                    ;;
               --log|--logging)
                    "$do_logging" && fatal "two --log* arguments" $ERR_CMDLINE
                    do_logging=true
                    ;;   # DEFINITION of LOGFILE if no arg specified: automagically in parse_hn_port()
                    # following does the same but additionally we can specify a log location
               --logfile|--logfile=*|-oL|-oL=*)
                    "$do_logging" && fatal "two --log* arguments" $ERR_CMDLINE
                    LOGFILE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    do_logging=true
                    ;;
               --json)
                    "$do_pretty_json" && fatal "flat and pretty JSON output are mutually exclusive" $ERR_CMDLINE
                    "$do_json" && fatal "--json and --jsonfile are mutually exclusive" $ERR_CMDLINE
                    do_json=true
                    ;;   # DEFINITION of JSONFILE is not arg specified: automagically in parse_hn_port()
                    # following does the same but additionally we can specify a log location
               --jsonfile|--jsonfile=*|-oj|-oj=*)
                    "$do_pretty_json"  && fatal "flat and pretty JSON output are mutually exclusive" $ERR_CMDLINE
                    "$do_json" && fatal "--json and --jsonfile are mutually exclusive" $ERR_CMDLINE
                    JSONFILE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    do_json=true
                    ;;
               --json-pretty)
                    "$do_json" && fatal "flat and pretty JSON output are mutually exclusive" $ERR_CMDLINE
                    "$do_pretty_json" && fatal "--json-pretty and --jsonfile-pretty are mutually exclusive" $ERR_CMDLINE
                    do_pretty_json=true
                    ;;
               --jsonfile-pretty|--jsonfile-pretty=*|-oJ|-oJ=*)
                    "$do_json" && fatal "flat and pretty JSON output are mutually exclusive" $ERR_CMDLINE
                    "$do_pretty_json" && fatal "--json-pretty and --jsonfile-pretty are mutually exclusive" $ERR_CMDLINE
                    JSONFILE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    do_pretty_json=true
                    ;;
               --severity|--severity=*)
                    set_severity_level "$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    ;;
               --hints)
                    GIVE_HINTS=true
                    ;;
               --csv)
                    "$do_csv" && fatal "two --csv* arguments" $ERR_CMDLINE
                    do_csv=true
                    ;;   # DEFINITION of CSVFILE is not arg specified: automagically in parse_hn_port()
                    # following does the same but additionally we can specify a log location
               --csvfile|--csvfile=*|-oC|-oC=*)
                    "$do_csv" && fatal "two --csv* arguments" $ERR_CMDLINE
                    CSVFILE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    do_csv=true
                    ;;
               --html)
                    "$do_html" && fatal "two --html* arguments" $ERR_CMDLINE
                    do_html=true
                    ;;  # DEFINITION of HTMLFILE is not arg specified: automagically in parse_hn_port()
                    # following does the same but additionally we can specify a file location
               --htmlfile|--htmlfile=*|-oH|-oH=*)
                    "$do_html" && fatal "two --html* arguments" $ERR_CMDLINE
                    HTMLFILE="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    do_html=true
                    ;;
               --outfile|--outfile=*|-oa|-oa=*)
                    ( "$do_html" || "$do_json" || "$do_pretty_json" || "$do_csv" || "$do_logging" ) && fatal "check your arguments four multiple file output options" $ERR_CMDLINE
                    outfile_arg="$(parse_opt_equal_sign "$1" "$2")"
                    if [[ "$outfile_arg" != "auto" ]]; then
                         if [[ -d "$outfile_arg" ]]; then
                              HTMLFILE="$outfile_arg"
                              CSVFILE="$outfile_arg"
                              JSONFILE="$outfile_arg"
                              LOGFILE="$outfile_arg"
                         else
                              HTMLFILE="$outfile_arg.html"
                              CSVFILE="$outfile_arg.csv"
                              JSONFILE="$outfile_arg.json"
                              LOGFILE="$outfile_arg.log"
                         fi
                    fi
                    [[ $? -eq 0 ]] && shift
                    do_html=true
                    do_json=true
                    do_csv=true
                    do_logging=true
                    ;;
               --outFile|--outFile=*|-oA|-oA=*)
                    ( "$do_html" || "$do_json" || "$do_pretty_json" || "$do_csv" || "$do_logging" ) && fatal "check your arguments four multiple file output options" $ERR_CMDLINE
                    outfile_arg="$(parse_opt_equal_sign "$1" "$2")"
                    if [[ "$outfile_arg" != "auto" ]]; then
                         if [[ -d "$outfile_arg" ]]; then
                              HTMLFILE="$outfile_arg"
                              CSVFILE="$outfile_arg"
                              JSONFILE="$outfile_arg"
                              LOGFILE="$outfile_arg"
                         else
                              HTMLFILE="$outfile_arg.html"
                              CSVFILE="$outfile_arg.csv"
                              JSONFILE="$outfile_arg.json"
                              LOGFILE="$outfile_arg.log"
                         fi
                    fi
                    [[ $? -eq 0 ]] && shift
                    do_html=true
                    do_pretty_json=true
                    do_csv=true
                    do_logging=true
                    ;;
               --append)
                    APPEND=true
                    ;;
               --outprefix)
                    FNAME_PREFIX="$(parse_opt_equal_sign "$1" "$2")"
                    if [[ $? -eq 0 ]]; then
                         shift
                         case "$(get_last_char "$FNAME_PREFIX")" in
                              '.') ;;
                              '-') ;;
                              '_') ;;
                              *) FNAME_PREFIX="${FNAME_PREFIX}-" ;;
                         esac
                    fi
                    ;;
               --openssl|--openssl=*)
                    OPENSSL="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    ;;
               --openssl-timeout|--openssl-timeout=*)
                    OPENSSL_TIMEOUT="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    ;;
               --mapping|--mapping=*)
                    cipher_mapping="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    case "$cipher_mapping" in
                         no-openssl) DISPLAY_CIPHERNAMES="rfc-only" ;;
                         no-rfc|no-iana) DISPLAY_CIPHERNAMES="openssl-only" ;;
                         openssl) DISPLAY_CIPHERNAMES="openssl" ;;
                         rfc|iana) DISPLAY_CIPHERNAMES="rfc" ;;
                         *)   tmln_warning "\nmapping can only be \"no-openssl\", \"no-iana\"(\"no-rfc\"), \"openssl\" or \"iana\"(\"rfc\")"
                              help 1 ;;
                    esac
                    ;;
               --proxy|--proxy=*)
                    PROXY="$(parse_opt_equal_sign "$1" "$2")"
                    [[ $? -eq 0 ]] && shift
                    ;;
               --phone-out)
                    PHONE_OUT=true
                    ;;
               -6)  # doesn't work automagically. My versions have -DOPENSSL_USE_IPV6, CentOS/RHEL/FC do not
                    HAS_IPv6=true
                    ;;
               --has[-_]dhbits|--has[_-]dh[-_]bits)
                    # Should work automagically. Helper switch for CentOS,RHEL+FC w openssl server temp key backport (version 1.0.1), see #190
                    HAS_DH_BITS=true
                    ;;
               --ssl_native|--ssl-native)
                    SSL_NATIVE=true
                    ;;
               (--) shift
                    break
                    ;;
               (-*) tmln_warning "0: unrecognized option \"$1\"" 1>&2;
                    help 1
                    ;;
               (*)  break
                    ;;
          esac
          shift
     done

     # Show usage if no further options were specified
     if [[ -z "$1" ]] && [[ -z "$FNAME" ]] && ! "$do_display_only"; then
          fatal "URI missing" $ERR_CMDLINE
     else
     # What is left here should be the URI.
          URI="$1"
          [[ -n "$2" ]] && fatal "URI comes last" $ERR_CMDLINE
     fi
     [[ $CMDLINE_IP == one ]] && [[ "$NODNS" == none ]] && fatal "\"--ip=one\" and \"--nodns=none\" don't work together" $ERR_CMDLINE
     [[ $CMDLINE_IP == one ]] && ( is_ipv4addr "$URI" || is_ipv6addr "$URI" )  && fatal "\"--ip=one\" plus supplying an IP address doesn't work" $ERR_CMDLINE
     "$do_mx_all_ips" && [[ "$NODNS" == none ]] && fatal "\"--mx\" and \"--nodns=none\" don't work together" $ERR_CMDLINE

     ADDITIONAL_CA_FILES="${ADDITIONAL_CA_FILES//,/ }"
     for fname in $ADDITIONAL_CA_FILES; do
          [[ -s "$fname" ]] || fatal "CA file \"$fname\" does not exist" $ERR_RESOURCE
          grep -q "BEGIN CERTIFICATE" "$fname" || fatal "\"$fname\" is not CA file in PEM format" $ERR_RESOURCE
     done

     [[ "$DEBUG" -ge 5 ]] && debug_globals
     # if we have no "do_*" set here --> query_globals: we do a standard run -- otherwise just the one specified
     query_globals && set_scanning_defaults
}


# connect call from openssl needs ipv6 in square brackets
nodeip_to_proper_ip6() {
     local len_nodeip=0

     if is_ipv6addr $NODEIP; then
          ${UNBRACKTD_IPV6} || NODEIP="[$NODEIP]"
          len_nodeip=${#NODEIP}
          CORRECT_SPACES="$(printf -- " "'%.s' $(eval "echo {1.."$((len_nodeip - 17))"}"))"
          # IPv6 addresses are longer, this variable takes care that "further IP" and "Service" is properly aligned
     fi
}


reset_hostdepended_vars() {
     TLS_EXTENSIONS=""
     PROTOS_OFFERED=""
     CURVES_OFFERED=""
     OPTIMAL_PROTO=""
     ALL_FAILED_SOCKETS=true
     SERVER_SIZE_LIMIT_BUG=false
}

# Rough estimate, in the future we maybe want to make use of nano secs (%N). Note this
# is for performance debugging purposes (MEASURE_TIME=yes), eye candy is not important.
#
stopwatch() {
     local new_delta
     local column=$((COLUMNS - 0))           # for future adjustments

     "$MEASURE_TIME" || return
     new_delta=$(( $(date +%s) - LAST_TIME ))
     printf "%${column}s" "$1: $new_delta"
     [[ -e "$MEASURE_TIME_FILE" ]] && echo "$1 : $new_delta " >> "$MEASURE_TIME_FILE"
     LAST_TIME=$(( new_delta + LAST_TIME ))
}


# arg1(optional): "init" --> just initializing. Or: STARTTLS protocol
lets_roll() {
     local -i ret=0
     local section_number=0

     if [[ "$1" == init ]]; then
          # called once upfront to be able to measure preparation time b4 everything starts
          START_TIME=$(date +%s)
          LAST_TIME=$START_TIME
          [[ -n "$MEASURE_TIME_FILE" ]] && >"$MEASURE_TIME_FILE"
          return 0
     fi
     stopwatch initialized

     [[ -z "$NODEIP" ]] && fatal "$NODE doesn't resolve to an IP address" $ERR_DNSLOOKUP
     nodeip_to_proper_ip6
     reset_hostdepended_vars
     determine_rdns                # Returns always zero or has already exited if fatal error occurred
     stopwatch determine_rdns

     ((SERVER_COUNTER++))
     datebanner " Start"
     determine_service "$1"        # STARTTLS service? Other will be determined here too. Returns 0 if test connect was ok or has already exited if fatal error occurred
                                   # determine_service() can return 1, it indicates that this IP cannot be reached but there are more IPs to check
     if [[ $? -eq 0 ]] ; then
          # "secret" devel options --devel:
          if "$do_tls_sockets"; then
               if [[ "$TLS_LOW_BYTE" == 22 ]]; then
                    sslv2_sockets "" "true"
               else
                    if [[ "$TLS_LOW_BYTE" == 04 ]]; then
                         if "$CERT_COMPRESSION"; then
                              # See PR #1279
                              [[ $DEBUG -eq 3 ]] && tmln_out "including TLS extension certificate compression"
                              tls_sockets "$TLS_LOW_BYTE" "$HEX_CIPHER" "all+" "00,1b, 00,03, 02, 00,01"
                         else
                              tls_sockets "$TLS_LOW_BYTE" "$HEX_CIPHER" "ephemeralkey"
                         fi
                    else
                         tls_sockets "$TLS_LOW_BYTE" "$HEX_CIPHER" "all"
                    fi
               fi
               echo $?
               exit $ALLOK;
          fi
          if "$do_cipher_match"; then
               # we will have an invalid JSON with no if statement
               fileout_section_header $section_number false
               run_cipher_match ${single_cipher}
               stopwatch run_cipher_match
          else
               fileout_section_header $section_number false && ((section_number++))
               determine_sizelimitbug
               fileout_section_footer false

               ((section_number++))
               # all top level functions now following have the prefix "run_"
               fileout_section_header $section_number false && ((section_number++))
               "$do_protocols" && {
                    run_protocols; ret=$(($? + ret)); stopwatch run_protocols;
                    run_npn; ret=$(($? + ret)); stopwatch run_npn;
                    run_alpn; ret=$(($? + ret)); stopwatch run_alpn;
               }
               fileout_section_header $section_number true && ((section_number++))
               "$do_grease" && { run_grease; ret=$(($? + ret)); stopwatch run_grease; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_cipherlists" && { run_cipherlists; ret=$(($? + ret)); stopwatch run_cipherlists; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_pfs" && { run_pfs; ret=$(($? + ret)); stopwatch run_pfs; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_server_preference" && { run_server_preference; ret=$(($? + ret)); stopwatch run_server_preference; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_server_defaults" && { run_server_defaults; ret=$(($? + ret)); stopwatch run_server_defaults; }

               if "$do_header"; then
                    #TODO: refactor this into functions
                    fileout_section_header $section_number true && ((section_number++))
                         if [[ $SERVICE == HTTP ]]; then
                              run_http_header "$URL_PATH";       ret=$(($? + ret))
                              run_http_date "$URL_PATH";         ret=$(($? + ret))
                              run_hsts "$URL_PATH";              ret=$(($? + ret))
                              run_hpkp "$URL_PATH";              ret=$(($? + ret))
                              run_server_banner "$URL_PATH";     ret=$(($? + ret))
                              run_appl_banner "$URL_PATH";       ret=$(($? + ret))
                              run_cookie_flags "$URL_PATH";      ret=$(($? + ret))
                              run_security_headers "$URL_PATH";  ret=$(($? + ret))
                              run_rp_banner "$URL_PATH";         ret=$(($? + ret))
                              stopwatch do_header
                         fi
               else
                    ((section_number++))
               fi

               # vulnerabilities
               if [[ $VULN_COUNT -gt $VULN_THRESHLD ]] || "$do_vulnerabilities"; then
                    outln; pr_headlineln " Testing vulnerabilities "
                    outln
               fi

               fileout_section_header $section_number true && ((section_number++))
               "$do_heartbleed" && { run_heartbleed; ret=$(($? + ret)); stopwatch run_heartbleed; }
               "$do_ccs_injection" && { run_ccs_injection; ret=$(($? + ret)); stopwatch run_ccs_injection; }
               "$do_ticketbleed" && { run_ticketbleed; ret=$(($? + ret)); stopwatch run_ticketbleed; }
               "$do_robot" && { run_robot; ret=$(($? + ret)); stopwatch run_robot; }
               "$do_renego" && { run_renego; ret=$(($? + ret)); stopwatch run_renego; }
               "$do_crime" && { run_crime; ret=$(($? + ret)); stopwatch run_crime; }
               "$do_breach" && { run_breach "$URL_PATH" ; ret=$(($? + ret));  stopwatch run_breach; }
               "$do_ssl_poodle" && { run_ssl_poodle; ret=$(($? + ret)); stopwatch run_ssl_poodle; }
               "$do_tls_fallback_scsv" && { run_tls_fallback_scsv; ret=$(($? + ret)); stopwatch run_tls_fallback_scsv; }
               "$do_sweet32" && { run_sweet32; ret=$(($? + ret)); stopwatch run_sweet32; }
               "$do_freak" && { run_freak; ret=$(($? + ret)); stopwatch run_freak; }
               "$do_drown" && { run_drown ret=$(($? + ret)); stopwatch run_drown; }
               "$do_logjam" && { run_logjam; ret=$(($? + ret)); stopwatch run_logjam; }
               "$do_beast" && { run_beast; ret=$(($? + ret)); stopwatch run_beast; }
               "$do_lucky13" && { run_lucky13; ret=$(($? + ret)); stopwatch run_lucky13; }
               "$do_rc4" && { run_rc4; ret=$(($? + ret)); stopwatch run_rc4; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_allciphers" && { run_allciphers; ret=$(($? + ret)); stopwatch run_allciphers; }
               "$do_cipher_per_proto" && { run_cipher_per_proto; ret=$(($? + ret)); stopwatch run_cipher_per_proto; }

               fileout_section_header $section_number true && ((section_number++))
               "$do_client_simulation" && { run_client_simulation; ret=$(($? + ret)); stopwatch run_client_simulation; }
          fi
         fileout_section_footer true
     fi

     outln
     calc_scantime
     datebanner " Done"

     # reset the failed connect counter as we are finished
     NR_SOCKET_FAIL=0
     NR_OSSL_FAIL=0

     "$MEASURE_TIME" && printf "$1: %${COLUMNS}s\n" "$SCAN_TIME"
     [[ -e "$MEASURE_TIME_FILE" ]] && echo "Total : $SCAN_TIME " >> "$MEASURE_TIME_FILE"

     return $ret
}



################# main #################


     RET=0     # this is a global as we can have a function main(), see #705. Should we toss then all local $ret?
     ip=""
     stopwatch start

     lets_roll init
     initialize_globals
     check_base_requirements            # needs to come after $do_html is defined
     parse_cmd_line "$@"
     # html_header() needs to be called early! Otherwise if html_out() is called before html_header() and the
     # command line contains --htmlfile <htmlfile> or --html, it'll make problems with html output, see #692.
     # json_header and csv_header could be called later but for context reasons we'll leave it here
     html_header
     json_header
     csv_header
     get_install_dir
     # see #705, we need to source TLS_DATA_FILE here instead of in get_install_dir(), see #705
     [[ -r "$TLS_DATA_FILE" ]] && . "$TLS_DATA_FILE"
     set_color_functions
     maketempf
     find_openssl_binary
     choose_printf
     check_resolver_bins
     prepare_debug  ; stopwatch parse
     prepare_arrays ; stopwatch prepare_arrays
     mybanner
     check_proxy
     check4openssl_oldfarts
     check_bsd_mount


     if "$do_display_only"; then
          prettyprint_local "$PATTERN2SHOW"
          exit $?
     fi
     fileout_banner

     if "$do_mass_testing"; then
          prepare_logging
          if [[ "$MASS_TESTING_MODE" == parallel ]]; then
               run_mass_testing_parallel
          else
               run_mass_testing
          fi
          exit $?
     fi
     html_banner

     #TODO: there shouldn't be the need for a special case for --mx, only the ip addresses we would need upfront and the do-parser
     if "$do_mx_all_ips"; then
          query_globals                                # if we have just 1x "do_*" --> we do a standard run -- otherwise just the one specified
          [[ $? -eq 1 ]] && set_scanning_defaults
          run_mx_all_ips "${URI}" $PORT                # we should reduce run_mx_all_ips to the stuff necessary as ~15 lines later we have similar code
          exit $?
     fi

     [[ -z "$NODE" ]] && parse_hn_port "${URI}"        # NODE, URL_PATH, PORT, IPADDRs and IP46ADDR is set now
     prepare_logging

     if ! determine_ip_addresses; then
          fatal "No IP address could be determined" $ERR_DNSLOOKUP
     fi
     if [[ $(count_words "$IPADDRs") -gt 1 ]]; then    # we have more than one ipv4 address to check
          MULTIPLE_CHECKS=true
          pr_bold "Testing all IPv4 addresses (port $PORT): "; outln "$IPADDRs"
          for ip in $IPADDRs; do
               draw_line "-" $((TERM_WIDTH * 2 / 3))
               outln
               NODEIP="$ip"
               lets_roll "${STARTTLS_PROTOCOL}"
               RET=$((RET + $?))                       # RET value per IP address
          done
          draw_line "-" $((TERM_WIDTH * 2 / 3))
          outln
          pr_bold "Done testing now all IP addresses (on port $PORT): "; outln "$IPADDRs"
     else                                              # Just 1x ip4v to check, applies also if CMDLINE_IP was supplied
          NODEIP="$IPADDRs"
          lets_roll "${STARTTLS_PROTOCOL}"
          RET=$?
     fi

exit $RET

