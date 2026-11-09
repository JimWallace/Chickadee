select 'SUB=' || s.id from submissions s join users u on u.id = s.user_id
 where u.username = 'stu001' and s.test_setup_id = 'setup-' || md5('setup12') order by s.attempt_number desc limit 1;
select 'SETUP=' || id from test_setups where id = 'setup-' || md5('setup12');
select 'ASG=' || public_id from assignments where test_setup_id = 'setup-' || md5('setup12');
select 'ASG_PAST=' || public_id from assignments where test_setup_id = 'setup-' || md5('setup6');
