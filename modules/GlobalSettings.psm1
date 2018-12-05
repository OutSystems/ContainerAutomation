<#
    Requires a Full Path
    
    This will be the location where all the outputs will be placed:
        Where the bundles will be unzipped
    and, by default, where all artefacts are expected, for instance:
        Where to find the private.key
        Where to save the web.config if a different site from "Default Web Site" will be used
        Or whatever else a specific wrapper may require
#>
$global:ArtefactsBasePath=""
