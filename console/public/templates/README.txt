RYODAN / ALLOWLIST CSV TEMPLATES

Keep the filenames pioneer.csv, operative.csv and recruit.csv.
Each file starts with address, followed by one Ethereum address per line.
Empty lists must retain the address header.
Do not put private keys, seed phrases, names or emails in these files.
Assign each wallet to its highest tier only:
- Pioneer also grants Operative and Recruit access.
- Operative also grants Recruit access.
- Recruit grants Recruit access; Civilian is public.
Repeated addresses are deduplicated; the highest tier wins.
Invalid or zero addresses stop generation and must be corrected.

Default per-wallet caps: Pioneer 4 (pairs), Operative 10, Recruit 10,
Civilian 10. Default prices per key: 0.025 / 0.040 / 0.045 / 0.050 ETH.
Guaranteed capacity: Pioneer count * 4 + (Pioneer + Operative counts) * 10
must fit 6,166 paid keys. The 500 treasury keys are separate.

In Sale controls, select all three completed CSVs, choose the UTC freeze
moment, and generate the snapshot. Review counts and capacity; download
allowlist.json and check-data.js. Use these exact files for both the checker
and mint frontend. Archive the original CSVs privately with their hashes.
Upload the snapshot on chain BEFORE starting Pioneer: the root and counts
are frozen when the first phase starts. Phase caps/prices remain editable
within the contract constraints. Wallets need a proof for their first list mint.

These templates contain no production members. Downloading or generating
files does not send a blockchain transaction; loading the root requires
administrator review and a wallet signature.
