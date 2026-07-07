# LINKS workflow

This file is the single source of truth for submission and app links.

## App links

- Repository: https://github.com/Aditya-Sarna/opi-assignment-2-ovs
- CI workflow (stable): https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/workflows/capture.yml
- Assignment repository: https://github.com/sknrao/opi-assignment-2-2026
- Verification guide: https://github.com/Aditya-Sarna/opi-assignment-2-ovs/blob/main/SUBMIT.md
- Topology diagram: https://raw.githubusercontent.com/Aditya-Sarna/opi-assignment-2-ovs/main/diagrams/implemented_software_datapath_topology.png

## Option B (Pull Request) workflow

1. Fork the assignment repository you selected.
2. In the fork root, create the folder `aditya-sarna`.
3. Put all assignment deliverables inside that folder.
4. Ensure the assignment-required main files are present with exact names:
   - cluster_setup.sh
   - manifests.yaml
   - verification_flows.json
   - ping_results.txt
   - dpu_offload_concept.md
5. Keep supporting material (docs, diagrams, evidence, scripts) alongside those required files inside the same full-name folder.
6. Open the PR to the upstream assignment repository.

## Local pre-PR checklist

- Run syntax checks:
  - bash -n cluster_setup.sh verify_datapath.sh
  - python3 -m py_compile flows_to_json.py lab-console/gen_data.py diagrams/render_diagrams.py
- Verify JSON parses:
  - python3 -m json.tool verification_flows.json >/dev/null
- Regenerate app data links:
  - ./lab-console/sync.sh
