{
  description = "Qualcomm X Elite firmware extraction for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Device model -> firmware path mapping
      devicePaths = {
        "Acer Swift 14 AI (SF14-11)" = "ACER/SF14-11";
        "ASUS Vivobook S 15" = "ASUSTeK/vivobook-s15";
        "Dell XPS 13 9345" = "dell/xps13-9345";
        "HP Omnibook X 14" = "hp/omnibook-x14";
        "Lenovo ThinkPad T14s Gen 6" = "LENOVO/21N1";
        "Lenovo Yoga Slim 7x" = "LENOVO/83ED";
        "Microsoft Surface Laptop 7 (13.8 inch)" = "microsoft/Romulus";
        "Samsung Galaxy Book4 Edge" = "SAMSUNG/galaxy-book4-edge";
      };

      firmwareFiles = [
        "adsp_dtbs.elf"
        "adspr.jsn"
        "adsps.jsn"
        "adspua.jsn"
        "battmgr.jsn"
        "cdsp_dtbs.elf"
        "cdspr.jsn"
        "qcadsp8380.mbn"
        "qccdsp8380.mbn"
        "qcdxkmsuc8380.mbn"
      ];

      extractScript = pkgs.writeShellApplication {
        name = "qcom-firmware-extract";
        runtimeInputs = with pkgs; [
          dislocker
          util-linux
          coreutils
          findutils
          gnugrep
        ];
        text = ''
          set -euo pipefail

          WIN_FW_PATH="Windows/System32/DriverStore/FileRepository"
          OUTPUT_DIR="''${1:-./qcom-firmware}"
          SEARCH_PATH="''${2:-}"

          # Get device model
          device_model="$(tr -d '\0' </proc/device-tree/model)"

          case "$device_model" in
            "Acer Swift 14 AI (SF14-11)")
              device_path="ACER/SF14-11" ;;
            "ASUS Vivobook S 15")
              device_path="ASUSTeK/vivobook-s15" ;;
            "Dell XPS 13 9345")
              device_path="dell/xps13-9345" ;;
            "HP Omnibook X 14")
              device_path="hp/omnibook-x14" ;;
            "Lenovo ThinkPad T14s Gen 6")
              device_path="LENOVO/21N1" ;;
            "Lenovo Yoga Slim 7x")
              device_path="LENOVO/83ED" ;;
            "Microsoft Surface Laptop 7 (13.8 inch)")
              device_path="microsoft/Romulus" ;;
            "Samsung Galaxy Book4 Edge")
              device_path="SAMSUNG/galaxy-book4-edge" ;;
            *)
              echo "error: Device '$device_model' is not supported" >&2
              exit 1 ;;
          esac

          echo "Detected device: $device_model"
          echo "Firmware path: $device_path"

          tmpdir="$(mktemp -d)"
          mkdir -p "$tmpdir/dislocker" "$tmpdir/mnt"

          cleanup() {
            umount -qRf "$tmpdir/mnt" 2>/dev/null || true
            umount -qRf "$tmpdir/dislocker" 2>/dev/null || true
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT

                      if [ -z "$SEARCH_PATH" ]; then
            # Find partition
            part=$(lsblk -l -o NAME,FSTYPE | grep nvme0n1 | grep BitLocker | cut -d" " -f1 || true)
            nobitlocker=0

            if [ -z "$part" ]; then
              part=$(lsblk -l -o NAME,FSTYPE | grep -E -m 1 "(^nvme[0-9]n[0-9]p[0-9]{1,2}\s+ntfs$)" | cut -d" " -f1 || true)
              nobitlocker=1
            fi

            if [ -z "$part" ]; then
              echo "error: Failed to find Windows partition" >&2
              exit 1
            fi

            echo "Mounting Windows partition $part..."
            if [ "$nobitlocker" -eq 0 ]; then
              dislocker --readonly "/dev/$part" -- "$tmpdir/dislocker"
              # Use kernel ntfs3 driver (faster than FUSE ntfs-3g)
              mount -t ntfs3 -o loop,ro "$tmpdir/dislocker/dislocker-file" "$tmpdir/mnt"
            else
              # Use kernel ntfs3 driver
              mount -t ntfs3 -o ro "/dev/$part" "$tmpdir/mnt"
            fi
            SEARCH_PATH="$tmpdir/mnt/$WIN_FW_PATH"
          fi

          # Create output directory structure
          fw_output="$OUTPUT_DIR/lib/firmware/qcom/x1e80100/$device_path"
          mkdir -p "$fw_output"

          # Also save device path for the module
          echo "$device_path" > "$OUTPUT_DIR/.device-path"

          echo "Extracting firmware from $SEARCH_PATH..."
          for f in adsp_dtbs.elf adspr.jsn adsps.jsn adspua.jsn battmgr.jsn \
                   cdsp_dtbs.elf cdspr.jsn qcadsp8380.mbn qccdsp8380.mbn qcdxkmsuc8380.mbn; do
            echo "  $f"
            fw_path="$(find "$SEARCH_PATH" -name "$f" -exec ls -t {} + 2>/dev/null | head -n1)"
            if [ -n "$fw_path" ]; then
              cp "$fw_path" "$fw_output/"
            else
              echo "    warning: $f not found" >&2
            fi
          done

          echo ""
          echo "Firmware extracted to: $OUTPUT_DIR"
          echo ""
          echo "Add this to your NixOS configuration:"
          echo ""
          echo "  hardware.firmware = [ (pkgs.callPackage $OUTPUT_DIR {}) ];"
          echo ""
          echo "Or use the module from this flake with:"
          echo ""
          echo "  qcom-firmware.nixosModules.default"
          echo "  qcom-firmware.firmwarePath = \"$OUTPUT_DIR\";"
        '';
      };

      # Function to build firmware package from extracted files
      mkFirmwarePackage = firmwarePath: pkgs.stdenvNoCC.mkDerivation {
        pname = "qcom-x1e-firmware-extracted";
        version = "1.0.0";

        src = firmwarePath;

        installPhase = ''
          mkdir -p $out/lib/firmware
          cp -r lib/firmware/* $out/lib/firmware/
        '';

        meta = {
          description = "Extracted Qualcomm X Elite firmware";
          license = pkgs.lib.licenses.unfree;
          platforms = [ "aarch64-linux" ];
        };
      };

    in {
      packages.${system} = {
        extract = extractScript;
        default = extractScript;
      };

      # Helper to create firmware package
      lib.mkFirmwarePackage = mkFirmwarePackage;

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.hardware.qcom-x1e-firmware;
        in {
          options.hardware.qcom-x1e-firmware = {
            enable = lib.mkEnableOption "Qualcomm X Elite extracted firmware";

            firmwarePath = lib.mkOption {
              type = lib.types.path;
              description = "Path to extracted firmware directory";
              example = "/home/user/qcom-firmware";
            };
          };

          config = lib.mkIf cfg.enable {
            hardware.firmware = [
              (pkgs.stdenvNoCC.mkDerivation {
                pname = "qcom-x1e-firmware-extracted";
                version = "1.0.0";
                src = cfg.firmwarePath;
                installPhase = ''
                  mkdir -p $out/lib/firmware
                  if [ -d lib/firmware ]; then
                    cp -r lib/firmware/* $out/lib/firmware/
                  else
                    cp -r * $out/lib/firmware/
                  fi
                '';
              })
            ];
          };
        };
    };
}
