# Configuration file for MemPool

The `config.mk` file is included by all *Makefiles* in the MemPool project to have
a common source for all configurations. Please only edit this file to change some
parameters such as the number of cores in the design. This will automatically
generate the correct software runtime and the correct hardware.

The `config.mk` file includes other configuration files, which represent specific
flavors of MemPool. We currently support two flavors:
- `mempool`: 256 cores, organized into 64 tiles with four cores each (default)
- `minpool`: 16 cores, organized into 4 tiles with four cores each

Use the `config` variable to define which configuration to take. For example,
to run a simulation with the `minpool` configuration, you would run
```
config=minpool make -C hardware verilate
```
Alternatively, you can also define the `MEMPOOL_CONFIGURATION` environment
variable, which has less priority than an explicit `config=` configuration.
Please run `make clean` before changing configurations.

To avoid constantly having a dirty git environment when working with a
configuration that differs from the default one, you can ignore changes to the
configuration file with the following command:

```bash
git update-index --assume-unchanged config/config.mk
```

In case you want to change the default and commit your changes to `config.mk`,
you can use the following command to make git pick up tracking the file again:

```bash
git update-index --no-assume-unchanged config/config.mk
```
