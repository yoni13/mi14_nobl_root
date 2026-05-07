# 免解锁 Bootloader Root 方案

**适用设备**: 小米 Xiaomi 14
**Root 方案**: KernelSU 32457 + NeoZygisk 2.3 + LSPosed v2.0.2
**原理**: 利用 `miui.mqsas.IMQSNative` 服务的 root 执行漏洞，在运行时加载内核模块


```
bash ksu_oneclick.sh
```

Please see fork upstream for more details
