--start_ignore
\! gpconfig -c diskquota.naptime -v 2
\! gpconfig -r diskquota.worker_timeout
\! gpstop -u
--end_ignore

SHOW diskquota.naptime;
