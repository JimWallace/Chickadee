-- Deadline-shaped backlog: every pending 'bl-' row on one assignment (Lab 12).
update submissions set test_setup_id = 'setup-' || md5('setup12') where id like 'bl-%';
analyze submissions;
