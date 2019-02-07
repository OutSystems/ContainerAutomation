# Set here your infrastructure info

# The path where the plink and pscp executables are stored.
$global:PuTTYPath = "C:\putty\"

# The hostname of the NGiNX Machine to which the scripts will try to connect.
$global:NGINXFQMN = ""

# The username for the user with permissions to read/write the location config
# files and to restart the NGiNX service.
$global:NGINXUser = ""

# The user password.
$global:NGINXPassword = ""

# The Certificate Fingerprint/Thumbprint used by pscp and plink executables to
# validate the host machine to which it is connecting.
$global:NGINXHostKey = ""
