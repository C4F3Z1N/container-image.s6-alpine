FROM docker.io/library/alpine:3.16 AS base

FROM base AS download

ARG S6_OVERLAY_VERSION

# http://skarnet.org/software/execline/dieshdiedie.html
RUN apk add --no-cache curl execline yq
RUN execlineb -c ' \
		# detect architecture;
		backtick -E arch { \
			backtick -E _arch { apk --print-arch } \
			ifelse { heredoc 0 ${_arch} grep -q "armv7" } { echo "armhf" } \
			ifelse { heredoc 0 ${_arch} grep -q "arm" } { echo "arm" } \
			echo ${_arch} \
		} \
		# change to a temporary working directory;
		backtick -E PWD { mktemp -d } \
		execline-cd ${PWD} \
		# save the API query result locally;
		if { curl -sL "https://api.github.com/repos/just-containers/s6-overlay/releases" -o result.json } \
		# determine version;
		backtick -E S6_OVERLAY_VERSION { \
			# retrieve the latest version if ${S6_OVERLAY_VERSION} is not defined;
			if -nt { printenv S6_OVERLAY_VERSION } \
			yq eval "[ .[] | .tag_name ] | sort | .[-1]" result.json \
		} \
		# download required artifacts;
		if { \
			forbacktickx -o 0 -E url { \
				yq " \
					.[] | \
					select(.tag_name==\"${S6_OVERLAY_VERSION}\") | \
					.assets[] | \
					select(.name | test(\"s6-overlay-noarch|s6-overlay-${arch}\")) | \
					.browser_download_url \
				" result.json \
			} \
			curl -LO ${url} -w "Filename: %{filename_effective}\n" \
		} \
		# validate checksums;
		if { \
			elglob items "*.sha256" \
			forx -o 0 -E i { ${items} } \
			sha256sum -cs ${i} \
		} \
		# extract files in the correct order;
		if { \
			foreground { mkdir -pv ./overlay-rootfs } \
			forx -o 0 -E i { "s6-overlay-noarch.tar.xz" "s6-overlay-${arch}.tar.xz" } \
			tar -C ./overlay-rootfs -Jxpf ${i} \
		} \
		# make them available for the next step(s);
		ln -fsv ${PWD} /tmp/downloads \
	'

FROM base

COPY --from=download /tmp/downloads/overlay-rootfs /
COPY ./overlay-rootfs /

ENV PATH="/command:$PATH"

RUN apk add --no-cache patch
RUN execlineb -c ' \
		forbacktickx -o 0 -E patch { find / -name "*.patch" } \
		backtick -E destination { heredoc 0 ${patch} sed "s/.patch//" } \
		foreground { patch --verbose ${destination} ${patch} } \
		importas -iu ? ? \
		foreground { rm -fv ${patch} } \
		exit ${?} \
	'

CMD /init
