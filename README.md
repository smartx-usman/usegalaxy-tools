# usegalaxy.\* tools

**WORK IN PROGRESS**

## Using these tools

### Tips

Use `make TOOLSET=<toolset_dir> <target>` to limit a make action to a specific toolset subdirectory, e.g.:

```console
$ make TOOLSET=usegalaxy.org lint
find ./usegalaxy.org -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 python scripts/fix-lockfile.py
find ./usegalaxy.org -name '*.yml' | grep '^\./[^/]*/' | xargs -n 1 -P 8 -I{} pykwalify -d '{}' -s .schema.yml
 INFO - validation.valid
 INFO - validation.valid
 ...
```
# Instructions for requesters:

*Anyone* can request tool installations or updates on [usegalaxy.org](https://usegalaxy.org/) or [test.galaxyproject.org](https://test.galaxyproject.org).
In the commands below fill the `{server_name}` as appropriate (usegalaxy.org, test.galaxyproject.org)

1. Fork and clone [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
1. Create/activate a virtualenv and `pip install -r requirements.txt`
1. You are either installing a new repo or updating existing repo
    - **NEW REPO**
        1. If this is a new a section without an existing yml file create a new one like this:
            1. Determine the desired section label
            1. Normalize the section label to an ID/filename with [this process](https://github.com/galaxyproject/usegalaxy-tools/issues/9#issuecomment-500847395)
            1. Create `{server_name}/<section_id>.yml` setting `tool_panel_section_label` from the section label obtained in previous step (see existing yml files for exact syntax)
            1. Continue with the steps below
        1. Add the entry for the new tool to the section yml [example](https://github.com/galaxyproject/usegalaxy-tools/pull/86/files#diff-7de70f8620e8ba71104b398d57087611R25-R26)
        1. Run `$ make TOOLSET={server_name} fix` and then `$ git add <file>` only the updates that you care about.
    - **UPDATE REPO**
        1. Find the yml and yml.lock files with the repository entries. Add the changeset hash of repo's desired *installable revision* to the yml.lock file [example](https://github.com/galaxyproject/usegalaxy-tools/pull/80/files#diff-2e7bd27ec27fa6be24b5689cebc77defR62-R64)
        - Alternatively run `$ make TOOLSET={server_name} fix` and then `$ git add <file>` only the updates that you care about.
1. Run `make TOOLSET={server_name} lint`
1. Commit `{server_name}/<repo>.yaml{.lock}`
1. Create a PR against the `master` branch of [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools)
    - Use PR labels as appropriate
    - To aid PR mergers, you can include information on tools in the repo's use of `$GALAXY_SLOTS`, or even PR any needed update(s) to [Main's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/main/templates/galaxy/config/job_conf.xml.j2) as explained in the "[Determine tool requirements](#determine-tool-requirements)" section once the test installation (via Travis) succeeds (see details below)
1. Once the PR is merged and the tool appears on [usegalaxy.org](https://usegalaxy.org/) or [test.galaxyproject.org](https://test.galaxyproject.org), test to ensure the tool works


# Instructions for tool installers

Members of the @galaxyproject/tool-installers group can deploy and merge tool installation/update PRs.

1. Review PRs to [usegalaxy-tools](https://github.com/galaxyproject/usegalaxy-tools) and verify that tool(s) to install are acceptable
1. Wait for the test installation (via Jenkins) to complete
1. Review the test installation output to ensure the tool appears to have installed correctly
    1. You can re-trigger the installation test by commenting on PR with `@galaxybot test this`
1. If any tools to install or update use `$GALAXY_SLOTS`:
    1. Check that the tool is assigned to the multi partition in [Main's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/main/templates/galaxy/config/job_conf.xml.j2) (or [Test's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/test/templates/galaxy/config/job_conf.xml.j2))
    1. If any updates are needed, commit them to [Main's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/main/templates/galaxy/config/job_conf.xml.j2) (or [Test's job_conf.xml](https://github.com/galaxyproject/usegalaxy-playbook/blob/master/env/test/templates/galaxy/config/job_conf.xml.j2)) as explained in the "[Determine tool requirements](#determine-tool-requirements)" section and run `ansible-env main|test config` as described below (if you have access to do so) or PR the update(s) and request that someone with access merge and run the config playbook (if you do not have access)
1. Trigger the deployment commenting on PR using phrase `@galaxybot deploy this`
1. Check the deployment on Jenkins to ensure that the installation completes successfully
1. Ensure the tool is installed (CVMFS Stratum 1 snapshots occur at :00, :15, :30, and :45; larger installs can take a while to transfer)
1. Test to ensure the tool works and (using metrics) is assigned the correct number of slots
1. Merge the PR