To use Shepherd, you must first install the `sheepctl` CLI tool. You MUST be connected to the VPN to use Shepherd.

A more detailed guide to getting started with Shepherd and TKG test pools can be found here: https://confluence.eng.vmware.com/pages/viewpage.action?spaceKey=TKG&title=TKG+Testbed

## Installing sheepctl

###  on Linux
```
wget http://files.pks.eng.vmware.com/ci/artifacts/shepherd/latest/sheepctl-linux-amd64
cp sheepctl-linux-amd64 /usr/local/bin/
chmod +x /usr/local/bin/sheepctl
```
###  on MacOS
```
brew tap vmware/internal git@gitlab.eng.vmware.com:homebrew/internal.git
brew install sheepctl
```

To run the `run-tests.sh` script, you will need to clone a few git repos first:

```
git clone git@github.com:pivotal/scdf-k8s-packaging
git clone git@github.com:pivotal/scdf-pro.git
git clonegit@github.com:spring-cloud/spring-cloud-dataflow-acceptance-tests.git
```

next, you will need to modify the script to use proper JFROG and Docker Hub credentials.