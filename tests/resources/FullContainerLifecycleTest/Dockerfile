FROM microsoft/aspnet:4.7.2
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop';"]

COPY modules modules
COPY scripts scripts

RUN ./scripts/deploy_modules.ps1
