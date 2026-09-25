#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* NVIDIA RM control ABI values, as defined in NVIDIA's open kernel headers. */
#define NV_IOCTL_MAGIC 'F'
#define NV_ESC_RM_CONTROL 0x2a
#define NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS 0x0201u
#define NV0000_CTRL_CMD_GPU_GET_PCI_INFO 0x021bu
#define NV0000_CTRL_GPU_MAX_ATTACHED_GPUS 32u
#define NV0000_CTRL_GPU_INVALID_ID 0xffffffffu
#define MAX_PROC_GPU_ENTRIES 256u

typedef struct {
  uint32_t hClient;
  uint32_t hObject;
  uint32_t cmd;
  uint32_t flags;
  void *params __attribute__((aligned(8)));
  uint32_t paramsSize;
  int32_t status;
} nv_os54_parameters;

typedef struct {
  uint32_t gpuIds[NV0000_CTRL_GPU_MAX_ATTACHED_GPUS];
} nv_get_attached_ids_parameters;

typedef struct {
  uint32_t gpuId;
  uint32_t domain;
  uint16_t bus;
  uint16_t slot;
} nv_get_pci_info_parameters;

typedef struct {
  uint32_t domain_bus;
  unsigned int slot;
  unsigned int function;
  int device_minor;
} gpu_mapping;

#ifndef NVENC_FIX_TEST
typedef int (*ioctl_fn)(int, unsigned long, ...);
static __thread ioctl_fn real_ioctl;
static int has_logged;
#endif

static uint32_t gpu_id_domain_bus(uint32_t gpu_id) {
  return (gpu_id >> 8) & 0x00ffffffu;
}

static int parse_bdf(const char *name, uint32_t *domain_bus) {
  unsigned int domain, bus, device, function;
  char extra;

  if (sscanf(name, "%x:%x:%x.%x%c", &domain, &bus, &device, &function,
             &extra) != 4 ||
      domain > 0xffffu || bus > 0xffu || device > 0xffu || function > 0xfu) {
    return 0;
  }
  *domain_bus = ((uint32_t)domain << 8) | (uint32_t)bus;
  return 1;
}

static size_t load_gpu_mappings(const char *info_dir, gpu_mapping *mappings,
                                size_t capacity) {
  DIR *dir = opendir(info_dir);
  if (!dir) return 0;

  size_t count = 0;
  struct dirent *entry;
  while (count < capacity && (entry = readdir(dir)) != NULL) {
    uint32_t domain_bus;
    if (!parse_bdf(entry->d_name, &domain_bus)) continue;

    char path[1024];
    int path_len = snprintf(path, sizeof(path), "%s/%s/information", info_dir,
                            entry->d_name);
    if (path_len < 0 || (size_t)path_len >= sizeof(path)) continue;

    FILE *info = fopen(path, "r");
    if (!info) continue;

    int device_minor = -1;
    char line[256];
    while (fgets(line, sizeof(line), info)) {
      if (sscanf(line, " Device Minor: %d", &device_minor) == 1) break;
    }
    fclose(info);
    if (device_minor < 0) continue;

    mappings[count].domain_bus = domain_bus;
    (void)sscanf(entry->d_name, "%*x:%*x:%x.%x", &mappings[count].slot,
                 &mappings[count].function);
    mappings[count].device_minor = device_minor;
    count++;
  }
  closedir(dir);
  return count;
}

static int mapped_minor_for_gpu(uint32_t gpu_id, const gpu_mapping *mappings,
                                size_t mapping_count) {
  const uint32_t id_domain_bus = gpu_id_domain_bus(gpu_id);
  int bus_only_minor = -1;
  size_t bus_only_matches = 0;
  int exact_minor = -1;
  size_t exact_matches = 0;

  for (size_t i = 0; i < mapping_count; i++) {
    if (mappings[i].domain_bus == id_domain_bus) {
      exact_minor = mappings[i].device_minor;
      exact_matches++;
    }
    if ((mappings[i].domain_bus & 0xffu) == (id_domain_bus & 0xffu)) {
      bus_only_minor = mappings[i].device_minor;
      bus_only_matches++;
    }
  }

  if (exact_matches == 1) return exact_minor;
  if (exact_matches > 1) return -1;

  /* Some NVIDIA driver branches omit the PCI domain from gpuId. Only use the
     bus-only fallback if that bus is unique, so a multi-root host cannot map
     an ID to the wrong GPU. */
  return bus_only_matches == 1 ? bus_only_minor : -1;
}

#ifndef NVENC_FIX_TEST
static int mapped_minor_from_pci_info(int fd, const nv_os54_parameters *parent,
                                      uint32_t gpu_id,
                                      const gpu_mapping *mappings,
                                      size_t mapping_count) {
  nv_get_pci_info_parameters pci = {.gpuId = gpu_id};
  nv_os54_parameters query = *parent;
  query.cmd = NV0000_CTRL_CMD_GPU_GET_PCI_INFO;
  query.params = &pci;
  query.paramsSize = sizeof(pci);
  query.status = 0;

  unsigned long request =
      _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, nv_os54_parameters);
  int result = real_ioctl(fd, request, &query);
  if (result != 0 || query.status != 0) return -1;

  int minor = -1;
  size_t matches = 0;
  for (size_t i = 0; i < mapping_count; i++) {
    unsigned int map_domain = mappings[i].domain_bus >> 8;
    unsigned int map_bus = mappings[i].domain_bus & 0xffu;
    if (map_domain == pci.domain && map_bus == pci.bus &&
        mappings[i].slot == pci.slot) {
      minor = mappings[i].device_minor;
      matches++;
    }
  }
  return matches == 1 ? minor : -1;
}
#endif

#ifdef NVENC_FIX_TEST
static size_t filter_attached_gpu_ids(uint32_t *gpu_ids,
                                     const gpu_mapping *mappings,
                                     size_t mapping_count,
                                     const char *device_dir,
                                     size_t *original_count) {
  size_t total = 0;
  while (total < NV0000_CTRL_GPU_MAX_ATTACHED_GPUS &&
         gpu_ids[total] != NV0000_CTRL_GPU_INVALID_ID) {
    total++;
  }
  *original_count = total;

  uint32_t visible[NV0000_CTRL_GPU_MAX_ATTACHED_GPUS];
  size_t visible_count = 0;
  for (size_t i = 0; i < total; i++) {
    int minor = mapped_minor_for_gpu(gpu_ids[i], mappings, mapping_count);
    if (minor < 0) continue;

    char path[1024];
    int path_len = snprintf(path, sizeof(path), "%s/nvidia%d", device_dir,
                            minor);
    if (path_len < 0 || (size_t)path_len >= sizeof(path) ||
        access(path, F_OK) != 0) {
      continue;
    }
    visible[visible_count++] = gpu_ids[i];
  }

  /* Fail open when metadata cannot establish any mapping. The caller's
     startup NVENC probe still fails closed, so Tdarr will not register. */
  if (visible_count == 0) return 0;

  memcpy(gpu_ids, visible, visible_count * sizeof(visible[0]));
  for (size_t i = visible_count; i < NV0000_CTRL_GPU_MAX_ATTACHED_GPUS; i++) {
    gpu_ids[i] = NV0000_CTRL_GPU_INVALID_ID;
  }
  return visible_count;
}
#endif

static int is_attached_ids_ioctl(unsigned long request,
                                 const nv_os54_parameters *control) {
  return _IOC_TYPE(request) == NV_IOCTL_MAGIC &&
         _IOC_NR(request) == NV_ESC_RM_CONTROL && control != NULL &&
         control->cmd == NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS &&
         control->params != NULL &&
         control->paramsSize >= sizeof(nv_get_attached_ids_parameters) &&
         control->status == 0;
}

#ifndef NVENC_FIX_TEST
int ioctl(int fd, unsigned long request, ...) {
  if (!real_ioctl) {
    *(void **)(&real_ioctl) = dlsym(RTLD_NEXT, "ioctl");
    if (!real_ioctl) {
      errno = ENOSYS;
      return -1;
    }
  }

  /* Do not infer that an ioctl has no third argument from _IOC_DIR/_IOC_SIZE.
     NVIDIA's legacy control requests can use an argument even when those
     encoding bits are zero. Dropping it breaks CUDA initialization before
     the attached-GPU filter gets a chance to run. */
  va_list args;
  va_start(args, request);
  void *argument = va_arg(args, void *);
  va_end(args);
  int result = real_ioctl(fd, request, argument);
  if (result != 0) return result;

  nv_os54_parameters *control = argument;
  if (!is_attached_ids_ioctl(request, control)) return result;

  const char *info_dir = getenv("NVENC_FIX_GPU_INFO_DIR");
  if (!info_dir || !*info_dir) info_dir = "/proc/driver/nvidia/gpus";
  const char *device_dir = getenv("NVENC_FIX_DEVICE_DIR");
  if (!device_dir || !*device_dir) device_dir = "/dev";

  gpu_mapping mappings[MAX_PROC_GPU_ENTRIES];
  size_t mapping_count =
      load_gpu_mappings(info_dir, mappings, MAX_PROC_GPU_ENTRIES);
  nv_get_attached_ids_parameters *attached = control->params;
  size_t host_count = 0;
  uint32_t visible_ids[NV0000_CTRL_GPU_MAX_ATTACHED_GPUS];
  memcpy(visible_ids, attached->gpuIds, sizeof(visible_ids));
  size_t total = 0;
  while (total < NV0000_CTRL_GPU_MAX_ATTACHED_GPUS &&
         visible_ids[total] != NV0000_CTRL_GPU_INVALID_ID) {
    total++;
  }
  host_count = total;
  size_t visible_count = 0;
  for (size_t i = 0; i < total; i++) {
    int minor = mapped_minor_from_pci_info(fd, control, visible_ids[i],
                                           mappings, mapping_count);
    if (minor < 0) {
      minor = mapped_minor_for_gpu(visible_ids[i], mappings, mapping_count);
    }
    if (minor < 0) continue;

    char path[1024];
    int path_len = snprintf(path, sizeof(path), "%s/nvidia%d", device_dir,
                            minor);
    if (path_len < 0 || (size_t)path_len >= sizeof(path) ||
        access(path, F_OK) != 0) {
      continue;
    }
    visible_ids[visible_count++] = visible_ids[i];
  }

  if (visible_count > 0) {
    memcpy(attached->gpuIds, visible_ids,
           visible_count * sizeof(visible_ids[0]));
    for (size_t i = visible_count; i < NV0000_CTRL_GPU_MAX_ATTACHED_GPUS; i++) {
      attached->gpuIds[i] = NV0000_CTRL_GPU_INVALID_ID;
    }
  }

  if (!__sync_lock_test_and_set(&has_logged, 1)) {
    if (visible_count > 0) {
      fprintf(stderr,
              "NVENC device filter: %zu/%zu attached GPU(s) have matching "
              "mounted NVIDIA device nodes\n",
              visible_count, host_count);
    } else {
      fprintf(stderr,
              "NVENC device filter: could not map attached GPU IDs to "
              "mounted device nodes; leaving driver list unchanged\n");
    }
  }
  return result;
}
#else
int main(void) {
  char temp_dir[] = "/tmp/nvenc-filter-test.XXXXXX";
  if (!mkdtemp(temp_dir)) {
    perror("mkdtemp");
    return 1;
  }

  char info_dir[1024], device_dir[1024], gpu_info[1024], device_path[1024];
  snprintf(info_dir, sizeof(info_dir), "%s/proc", temp_dir);
  snprintf(device_dir, sizeof(device_dir), "%s/dev", temp_dir);
  if (mkdir(info_dir, 0700) != 0 || mkdir(device_dir, 0700) != 0) {
    perror("mkdir");
    return 1;
  }

  const char *bdfs[] = {"0000:45:00.0", "0000:52:00.0", "0000:63:00.0",
                        "0000:80:00.0"};
  const int minors[] = {4, 17, 38, 67};
  for (size_t i = 0; i < 4; i++) {
    char gpu_dir[1024];
    snprintf(gpu_dir, sizeof(gpu_dir), "%s/%s", info_dir, bdfs[i]);
    if (mkdir(gpu_dir, 0700) != 0) {
      perror("mkdir gpu info");
      return 1;
    }
    snprintf(gpu_info, sizeof(gpu_info), "%s/information", gpu_dir);
    FILE *info = fopen(gpu_info, "w");
    if (!info) {
      perror("fopen gpu info");
      return 1;
    }
    fprintf(info, "GPU UUID: GPU-TEST-%zu\nDevice Minor: %d\n", i,
            minors[i]);
    fclose(info);
  }

  /* Expose three GPUs on nonzero minors, including one above 31; leave one
     host GPU unmounted. */
  const int exposed[] = {4, 17, 67};
  for (size_t i = 0; i < 3; i++) {
    snprintf(device_path, sizeof(device_path), "%s/nvidia%d", device_dir,
             exposed[i]);
    int fd = open(device_path, O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
      perror("open device mock");
      return 1;
    }
    close(fd);
  }

  gpu_mapping mappings[MAX_PROC_GPU_ENTRIES];
  size_t mapping_count =
      load_gpu_mappings(info_dir, mappings, MAX_PROC_GPU_ENTRIES);
  if (mapping_count != 4) {
    fprintf(stderr, "expected 4 proc GPU mappings, got %zu\n", mapping_count);
    return 1;
  }

  uint32_t ids[NV0000_CTRL_GPU_MAX_ATTACHED_GPUS];
  for (size_t i = 0; i < NV0000_CTRL_GPU_MAX_ATTACHED_GPUS; i++) {
    ids[i] = NV0000_CTRL_GPU_INVALID_ID;
  }
  ids[0] = 0x00004500u;
  ids[1] = 0x00005200u;
  ids[2] = 0x00006300u;
  ids[3] = 0x00008000u;
  size_t original_count = 0;
  size_t visible_count = filter_attached_gpu_ids(
      ids, mappings, mapping_count, device_dir, &original_count);
  if (original_count != 4 || visible_count != 3 || ids[0] != 0x4500u ||
      ids[1] != 0x5200u || ids[2] != 0x8000u ||
      ids[3] != NV0000_CTRL_GPU_INVALID_ID) {
    fprintf(stderr, "nonzero device minor filtering test failed\n");
    return 1;
  }

  nv_os54_parameters control = {0};
  control.cmd = NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS;
  control.params = ids;
  control.paramsSize = sizeof(ids);
  control.status = 0;
  unsigned long request =
      _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, nv_os54_parameters);
  if (!is_attached_ids_ioctl(request, &control)) {
    fprintf(stderr, "NVENC RM ioctl signature test failed\n");
    return 1;
  }
  control.cmd++;
  if (is_attached_ids_ioctl(request, &control)) {
    fprintf(stderr, "unrelated RM ioctl was incorrectly matched\n");
    return 1;
  }

  snprintf(device_path, sizeof(device_path), "%s/nvidia4", device_dir);
  unlink(device_path);
  snprintf(device_path, sizeof(device_path), "%s/nvidia17", device_dir);
  unlink(device_path);
  snprintf(device_path, sizeof(device_path), "%s/nvidia67", device_dir);
  unlink(device_path);
  for (size_t i = 0; i < 4; i++) {
    snprintf(gpu_info, sizeof(gpu_info), "%s/%s/information", info_dir,
             bdfs[i]);
    unlink(gpu_info);
    snprintf(device_path, sizeof(device_path), "%s/%s", info_dir, bdfs[i]);
    rmdir(device_path);
  }
  rmdir(info_dir);
  rmdir(device_dir);
  rmdir(temp_dir);
  puts("PASS NVENC attached-GPU ioctl filtering for nonzero device minors");
  return 0;
}
#endif
