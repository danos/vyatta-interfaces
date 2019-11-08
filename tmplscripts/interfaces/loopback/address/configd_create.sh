#!/opt/vyatta/bin/cliexec

loamsg="Address 127.0.0.1/8 is reserved for system use."

#do not apply system loopback address on any loopback interface
#it still goes into config to keep compatibility with old behavior.
[[ $VAR(@) = 127.0.0.1/* || $VAR(@) = ::1/* ]] && \
  echo -e "$loamsg" >&2 && \
  exit 0

/opt/vyatta/sbin/vyatta-address add $VAR(../@) $VAR(@)
