#!/bin/bash

until nc phpfpm 9001 -z; do
  echo "Waiting for PHP on port 9001..."
  sleep 3
done

until nc phpfpm 9002 -z; do
  echo "Waiting for PHP on port 9002..."
  sleep 3
done

mkdir -p /etc/rspamd/plugins.d \
  /etc/rspamd/custom

touch /etc/rspamd/rspamd.conf.local \
  /etc/rspamd/rspamd.conf.override

chmod 755 /var/lib/rspamd


[[ ! -f /etc/rspamd/override.d/worker-controller-password.inc ]] && echo '# Autogenerated by mailcow' > /etc/rspamd/override.d/worker-controller-password.inc

echo ${IPV4_NETWORK}.0/24 > /etc/rspamd/custom/mailcow_networks.map
echo ${IPV6_NETWORK} >> /etc/rspamd/custom/mailcow_networks.map

DOVECOT_V4=
DOVECOT_V6=
until [[ ! -z ${DOVECOT_V4} ]]; do
  DOVECOT_V4=$(dig a dovecot +short)
  DOVECOT_V6=$(dig aaaa dovecot +short)
  [[ ! -z ${DOVECOT_V4} ]] && break;
  echo "Waiting for Dovecot..."
  sleep 3
done
echo ${DOVECOT_V4}/32 > /etc/rspamd/custom/dovecot_trusted.map
if [[ ! -z ${DOVECOT_V6} ]]; then
  echo ${DOVECOT_V6}/128 >> /etc/rspamd/custom/dovecot_trusted.map
fi

RSPAMD_V4=
RSPAMD_V6=
until [[ ! -z ${RSPAMD_V4} ]]; do
  RSPAMD_V4=$(dig a rspamd +short)
  RSPAMD_V6=$(dig aaaa rspamd +short)
  [[ ! -z ${RSPAMD_V4} ]] && break;
  echo "Waiting for Rspamd..."
  sleep 3
done
echo ${RSPAMD_V4}/32 > /etc/rspamd/custom/rspamd_trusted.map
if [[ ! -z ${RSPAMD_V6} ]]; then
  echo ${RSPAMD_V6}/128 >> /etc/rspamd/custom/rspamd_trusted.map
fi

if [[ ! -z ${REDIS_SLAVEOF_IP} ]]; then
  cat <<EOF > /etc/rspamd/local.d/redis.conf
read_servers = "redis:6379";
write_servers = "${REDIS_SLAVEOF_IP}:${REDIS_SLAVEOF_PORT}";
password = "${REDISPASS}";
timeout = 10;
EOF
  until [[ $(redis-cli -h redis-mailcow -a ${REDISPASS} --no-auth-warning PING) == "PONG" ]]; do
    echo "Waiting for Redis @redis-mailcow..."
    sleep 2
  done
  until [[ $(redis-cli -h ${REDIS_SLAVEOF_IP} -p ${REDIS_SLAVEOF_PORT} -a ${REDISPASS} --no-auth-warning PING) == "PONG" ]]; do
    echo "Waiting for Redis @${REDIS_SLAVEOF_IP}..."
    sleep 2
  done
  redis-cli -h redis-mailcow -a ${REDISPASS} --no-auth-warning SLAVEOF ${REDIS_SLAVEOF_IP} ${REDIS_SLAVEOF_PORT}
else
  cat <<EOF > /etc/rspamd/local.d/redis.conf
servers = "redis:6379";
password = "${REDISPASS}";
timeout = 10;
EOF
  until [[ $(redis-cli -h redis-mailcow -a ${REDISPASS} --no-auth-warning PING) == "PONG" ]]; do
    echo "Waiting for Redis slave..."
    sleep 2
  done
  redis-cli -h redis-mailcow -a ${REDISPASS} --no-auth-warning SLAVEOF NO ONE
fi

if [[ "${SKIP_OLEFY}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  if [[ -f /etc/rspamd/local.d/external_services.conf ]]; then
    rm /etc/rspamd/local.d/external_services.conf
  fi
else
  cat <<EOF > /etc/rspamd/local.d/external_services.conf
oletools {
  # default olefy settings
  servers = "olefy:10055";
  # needs to be set explicitly for Rspamd < 1.9.5
  scan_mime_parts = true;
  # mime-part regex matching in content-type or filename
  # block all macros
  extended = true;
  max_size = 3145728;
  timeout = 20.0;
  retransmits = 1;
}
EOF
fi

# Provide additional lua modules
ln -s /usr/lib/$(uname -m)-linux-gnu/liblua5.1-cjson.so.0.0.0 /usr/lib/rspamd/cjson.so

chown -R _rspamd:_rspamd /var/lib/rspamd \
  /etc/rspamd/local.d \
  /etc/rspamd/override.d \
  /etc/rspamd/rspamd.conf.local \
  /etc/rspamd/rspamd.conf.override \
  /etc/rspamd/plugins.d

# Fix missing default global maps, if any
# These exists in mailcow UI and should not be removed
touch /etc/rspamd/custom/global_mime_from_blacklist.map \
  /etc/rspamd/custom/global_rcpt_blacklist.map \
  /etc/rspamd/custom/global_smtp_from_blacklist.map \
  /etc/rspamd/custom/global_mime_from_whitelist.map \
  /etc/rspamd/custom/global_rcpt_whitelist.map \
  /etc/rspamd/custom/global_smtp_from_whitelist.map \
  /etc/rspamd/custom/bad_languages.map \
  /etc/rspamd/custom/sa-rules \
  /etc/rspamd/custom/dovecot_trusted.map \
  /etc/rspamd/custom/rspamd_trusted.map \
  /etc/rspamd/custom/mailcow_networks.map \
  /etc/rspamd/custom/ip_wl.map \
  /etc/rspamd/custom/fishy_tlds.map \
  /etc/rspamd/custom/bad_words.map \
  /etc/rspamd/custom/bad_asn.map \
  /etc/rspamd/custom/bad_words_de.map \
  /etc/rspamd/custom/bulk_header.map \
  /etc/rspamd/custom/bad_header.map

# www-data (82) group needs to write to these files
chown _rspamd:_rspamd /etc/rspamd/custom/
chmod 0755 /etc/rspamd/custom/.
chown -R 82:82 /etc/rspamd/custom/*
chmod 644 -R /etc/rspamd/custom/*

# Run hooks
for file in /hooks/*; do
  if [ -x "${file}" ]; then
    echo "Running hook ${file}"
    "${file}"
  fi
done

# If DQS KEY is set in mailcow.conf add Spamhaus DQS RBLs
if [[ ! -z ${SPAMHAUS_DQS_KEY} ]]; then
    cat <<EOF > /etc/rspamd/custom/dqs-rbl.conf
  # Autogenerated by mailcow. DO NOT TOUCH!
    spamhaus {
        rbl = "${SPAMHAUS_DQS_KEY}.zen.dq.spamhaus.net";
        from = false;
    }
    spamhaus_from {
        from = true;
        received = false;
        rbl = "${SPAMHAUS_DQS_KEY}.zen.dq.spamhaus.net";
        returncodes {
          SPAMHAUS_ZEN = [ "127.0.0.2", "127.0.0.3", "127.0.0.4", "127.0.0.5", "127.0.0.6", "127.0.0.7", "127.0.0.9", "127.0.0.10", "127.0.0.11" ];
        }
    }
    spamhaus_authbl_received {
        # Check if the sender client is listed in AuthBL (AuthBL is *not* part of ZEN)
        rbl = "${SPAMHAUS_DQS_KEY}.authbl.dq.spamhaus.net";
        from = false;
        received = true;
        ipv6 = true;
        returncodes {
          SH_AUTHBL_RECEIVED = "127.0.0.20"
        }
    }
    spamhaus_dbl {
        # Add checks on the HELO string
        rbl = "${SPAMHAUS_DQS_KEY}.dbl.dq.spamhaus.net";
        helo = true;
        rdns = true;
        dkim = true;
        disable_monitoring = true;
        returncodes {
            RBL_DBL_SPAM = "127.0.1.2";
            RBL_DBL_PHISH = "127.0.1.4";
            RBL_DBL_MALWARE = "127.0.1.5";
            RBL_DBL_BOTNET = "127.0.1.6";
            RBL_DBL_ABUSED_SPAM = "127.0.1.102";
            RBL_DBL_ABUSED_PHISH = "127.0.1.104";
            RBL_DBL_ABUSED_MALWARE = "127.0.1.105";
            RBL_DBL_ABUSED_BOTNET = "127.0.1.106";
            RBL_DBL_DONT_QUERY_IPS = "127.0.1.255";
        }
    }
    spamhaus_dbl_fullurls {
        ignore_defaults = true;
        no_ip = true;
        rbl = "${SPAMHAUS_DQS_KEY}.dbl.dq.spamhaus.net";
        selector = 'urls:get_host'
        disable_monitoring = true;
        returncodes {
            DBLABUSED_SPAM_FULLURLS = "127.0.1.102";
            DBLABUSED_PHISH_FULLURLS = "127.0.1.104";
            DBLABUSED_MALWARE_FULLURLS = "127.0.1.105";
            DBLABUSED_BOTNET_FULLURLS = "127.0.1.106";
        }
    }
    spamhaus_zrd {
        # Add checks on the HELO string also for DQS
        rbl = "${SPAMHAUS_DQS_KEY}.zrd.dq.spamhaus.net";
        helo = true;
        rdns = true;
        dkim = true;
        disable_monitoring = true;
        returncodes {
            RBL_ZRD_VERY_FRESH_DOMAIN = ["127.0.2.2", "127.0.2.3", "127.0.2.4"];
            RBL_ZRD_FRESH_DOMAIN = [
              "127.0.2.5", "127.0.2.6", "127.0.2.7", "127.0.2.8", "127.0.2.9", "127.0.2.10", "127.0.2.11", "127.0.2.12", "127.0.2.13", "127.0.2.14", "127.0.2.15", "127.0.2.16", "127.0.2.17", "127.0.2.18", "127.0.2.19", "127.0.2.20", "127.0.2.21", "127.0.2.22", "127.0.2.23", "127.0.2.24"
            ];
            RBL_ZRD_DONT_QUERY_IPS = "127.0.2.255";
        }
    }
    "SPAMHAUS_ZEN_URIBL" {
      enabled = true;
      rbl = "${SPAMHAUS_DQS_KEY}.zen.dq.spamhaus.net";
      resolve_ip = true;
      checks = ['urls'];
      replyto = true;
      emails = true;
      ipv4 = true;
      ipv6 = true;
      emails_domainonly = true;
      returncodes {
        URIBL_SBL = "127.0.0.2";
        URIBL_SBL_CSS = "127.0.0.3";
        URIBL_XBL = ["127.0.0.4", "127.0.0.5", "127.0.0.6", "127.0.0.7"];
        URIBL_PBL = ["127.0.0.10", "127.0.0.11"];
        URIBL_DROP = "127.0.0.9";
      }
    }
    SH_EMAIL_DBL {
      ignore_defaults = true;
      replyto = true;
      emails_domainonly = true;
      disable_monitoring = true;
      rbl = "${SPAMHAUS_DQS_KEY}.dbl.dq.spamhaus.net";
      returncodes = {
        SH_EMAIL_DBL = [
          "127.0.1.2",
          "127.0.1.4",
          "127.0.1.5",
          "127.0.1.6"
        ];
        SH_EMAIL_DBL_ABUSED = [
          "127.0.1.102",
          "127.0.1.104",
          "127.0.1.105",
          "127.0.1.106"
        ];
        SH_EMAIL_DBL_DONT_QUERY_IPS = [ "127.0.1.255" ];
      }
    }
    SH_EMAIL_ZRD {
      ignore_defaults = true;
      replyto = true;
      emails_domainonly = true;
      disable_monitoring = true;
      rbl = "${SPAMHAUS_DQS_KEY}.zrd.dq.spamhaus.net";
      returncodes = {
        SH_EMAIL_ZRD_VERY_FRESH_DOMAIN = ["127.0.2.2", "127.0.2.3", "127.0.2.4"];
        SH_EMAIL_ZRD_FRESH_DOMAIN = [
          "127.0.2.5", "127.0.2.6", "127.0.2.7", "127.0.2.8", "127.0.2.9", "127.0.2.10", "127.0.2.11", "127.0.2.12", "127.0.2.13", "127.0.2.14", "127.0.2.15", "127.0.2.16", "127.0.2.17", "127.0.2.18", "127.0.2.19", "127.0.2.20", "127.0.2.21", "127.0.2.22", "127.0.2.23", "127.0.2.24"
        ];
        SH_EMAIL_ZRD_DONT_QUERY_IPS = [ "127.0.2.255" ];
      }
    }
    "DBL" {
        # override the defaults for DBL defined in modules.d/rbl.conf
        rbl = "${SPAMHAUS_DQS_KEY}.dbl.dq.spamhaus.net";
        disable_monitoring = true;
    }
    "ZRD" {
        ignore_defaults = true;
        rbl = "${SPAMHAUS_DQS_KEY}.zrd.dq.spamhaus.net";
        no_ip = true;
        dkim = true;
        emails = true;
        emails_domainonly = true;
        urls = true;
        returncodes = {
            ZRD_VERY_FRESH_DOMAIN = ["127.0.2.2", "127.0.2.3", "127.0.2.4"];
            ZRD_FRESH_DOMAIN = ["127.0.2.5", "127.0.2.6", "127.0.2.7", "127.0.2.8", "127.0.2.9", "127.0.2.10", "127.0.2.11", "127.0.2.12", "127.0.2.13", "127.0.2.14", "127.0.2.15", "127.0.2.16", "127.0.2.17", "127.0.2.18", "127.0.2.19", "127.0.2.20", "127.0.2.21", "127.0.2.22", "127.0.2.23", "127.0.2.24"];
        }
    }
    spamhaus_sbl_url {
        ignore_defaults = true
        rbl = "${SPAMHAUS_DQS_KEY}.sbl.dq.spamhaus.net";
        checks = ['urls'];
        disable_monitoring = true;
        returncodes {
            SPAMHAUS_SBL_URL = "127.0.0.2";
        }
    }

    SH_HBL_EMAIL {
      ignore_defaults = true;
      rbl = "_email.${SPAMHAUS_DQS_KEY}.hbl.dq.spamhaus.net";
      emails_domainonly = false;
      selector = "from('smtp').lower;from('mime').lower";
      ignore_whitelist = true;
      checks = ['emails', 'replyto'];
      hash = "sha1";
      returncodes = {
        SH_HBL_EMAIL = [
          "127.0.3.2"
        ];
      }
    }

    spamhaus_dqs_hbl {
      symbol = "HBL_FILE_UNKNOWN";
      rbl = "_file.${SPAMHAUS_DQS_KEY}.hbl.dq.spamhaus.net.";
      selector = "attachments('rbase32', 'sha256')";
      ignore_whitelist = true;
      ignore_defaults = true;
      returncodes {
        SH_HBL_FILE_MALICIOUS = "127.0.3.10";
        SH_HBL_FILE_SUSPICIOUS = "127.0.3.15";
      }
    }
EOF
else
  rm -rf /etc/rspamd/custom/dqs-rbl.conf
fi

exec "$@"
