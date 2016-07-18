/* certwatch_db - Database schema
 * Written by Rob Stradling
 * Copyright (C) 2015-2016 COMODO CA Limited
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

CREATE OR REPLACE FUNCTION determine_ca_trust_purposes(
	max_iterations			integer		DEFAULT 20
) RETURNS integer
AS $$
DECLARE
	l_rtp				RECORD;
	l_ctp				RECORD;
	t_iteration			integer		:= 1;
	t_isTrusted			boolean;
	t_isRevoked			boolean;
	t_nothingChanged	boolean;
	t_caID				ca.ID%TYPE;
	t_ctp1				ca_trust_purpose_temp%ROWTYPE;
	t_ctp2				ca_trust_purpose_temp%ROWTYPE;
BEGIN
	INSERT INTO ca_trust_purpose_temp (
			CA_ID, TRUST_CONTEXT_ID, TRUST_PURPOSE_ID, PATH_LEN_CONSTRAINT,
			EARLIEST_NOT_BEFORE, LATEST_NOT_AFTER,
			ALL_CHAINS_TECHNICALLY_CONSTRAINED, ALL_CHAINS_REVOKED, LONGEST_CHAIN
		)
		SELECT cac.CA_ID, rtp.TRUST_CONTEXT_ID, rtp.TRUST_PURPOSE_ID, max_iterations,
				min(x509_notBefore(c.CERTIFICATE)), max(x509_notAfter(c.CERTIFICATE)),
				FALSE, FALSE, t_iteration
			FROM root_trust_purpose rtp, ca_certificate cac, certificate c
			WHERE rtp.CERTIFICATE_ID = cac.CERTIFICATE_ID
				AND cac.CERTIFICATE_ID = c.ID
			GROUP BY cac.CA_ID, rtp.TRUST_CONTEXT_ID,
					rtp.TRUST_PURPOSE_ID;

	WHILE t_iteration <= max_iterations LOOP
		t_nothingChanged := TRUE;
		FOR l_ctp IN (
					SELECT ctp.TRUST_CONTEXT_ID, ctp.TRUST_PURPOSE_ID,
							c.ID, c.ISSUER_CA_ID, c.CERTIFICATE,
							tp.PURPOSE, tp.PURPOSE_OID,
							ctp.PATH_LEN_CONSTRAINT,
							ctp.EARLIEST_NOT_BEFORE, ctp.LATEST_NOT_AFTER,
							ctp.ALL_CHAINS_TECHNICALLY_CONSTRAINED,
							ctp.ALL_CHAINS_REVOKED
						FROM ca_trust_purpose_temp ctp, trust_purpose tp,
							certificate c
						WHERE ctp.PATH_LEN_CONSTRAINT > 0
							AND ctp.LONGEST_CHAIN = t_iteration
							AND ctp.TRUST_PURPOSE_ID = tp.ID
							AND ctp.CA_ID = c.ISSUER_CA_ID
							AND x509_canIssueCerts(c.CERTIFICATE)
				) LOOP
			BEGIN
				t_isTrusted := FALSE;
				t_isRevoked := FALSE;
				SELECT cac.CA_ID
					INTO t_caID
					FROM ca_certificate cac
					WHERE cac.CERTIFICATE_ID = l_ctp.ID;
				SELECT true
					INTO t_isRevoked
					FROM mozilla_disclosure m
					WHERE m.CERTIFICATE_ID = l_ctp.ID
						AND m.DISCLOSURE_STATUS IN ('Revoked', 'RevokedViaOneCRL');
				IF l_ctp.PURPOSE = 'EV Server Authentication' THEN
					IF x509_isPolicyPermitted(l_ctp.CERTIFICATE,
												l_ctp.PURPOSE_OID) THEN
						IF x509_isEKUPermitted(l_ctp.CERTIFICATE,
												'1.3.6.1.5.5.7.3.1')
								OR x509_isEKUPermitted(l_ctp.CERTIFICATE,
												'1.3.6.1.4.1.311.10.3.3') THEN
							-- This EV Policy OID is permitted, and so is Server
							-- Authentication and/or SGC.
							t_isTrusted := TRUE;
						END IF;
					END IF;
				ELSIF x509_isEKUPermitted(l_ctp.CERTIFICATE,
											l_ctp.PURPOSE_OID) THEN
					t_isTrusted := TRUE;
				ELSIF (l_ctp.PURPOSE_OID = '1.3.6.1.5.5.7.3.1')
						AND x509_isEKUPermitted(l_ctp.CERTIFICATE,
												'1.3.6.1.4.1.311.10.3.3') THEN
					-- If SGC is present but Server Authentication is not
					-- present, act as if Server Authentication is present.
					t_isTrusted := TRUE;
				END IF;
				IF t_isTrusted THEN
					INSERT INTO ca_trust_purpose_temp (
							CA_ID,
							TRUST_CONTEXT_ID,
							TRUST_PURPOSE_ID,
							PATH_LEN_CONSTRAINT,
							EARLIEST_NOT_BEFORE,
							LATEST_NOT_AFTER,
							ALL_CHAINS_TECHNICALLY_CONSTRAINED,
							ALL_CHAINS_REVOKED,
							LONGEST_CHAIN
						)
						VALUES (
							coalesce(t_caID, -l_ctp.ID),
							-- -l_ctp.ID will generate an exception.  This is
							-- intentional.
							l_ctp.TRUST_CONTEXT_ID,
							l_ctp.TRUST_PURPOSE_ID,
							greatest(
								0,
								least(l_ctp.PATH_LEN_CONSTRAINT - 1,
										coalesce(x509_getPathLenConstraint(l_ctp.CERTIFICATE),
													max_iterations)
								)
							),
							greatest(l_ctp.EARLIEST_NOT_BEFORE, x509_notBefore(l_ctp.CERTIFICATE)),
							least(l_ctp.LATEST_NOT_AFTER, x509_notAfter(l_ctp.CERTIFICATE)),
							greatest(l_ctp.ALL_CHAINS_TECHNICALLY_CONSTRAINED,
										is_technically_constrained(l_ctp.CERTIFICATE)),
							greatest(l_ctp.ALL_CHAINS_REVOKED, t_isRevoked),
							t_iteration + 1
						);
					t_nothingChanged := FALSE;
				END IF;
			EXCEPTION
				WHEN unique_violation THEN
					IF t_isTrusted THEN
						SELECT *
							INTO t_ctp1
							FROM ca_trust_purpose_temp ctp
							WHERE ctp.CA_ID = coalesce(t_caID, -l_ctp.ID)
								AND TRUST_CONTEXT_ID = l_ctp.TRUST_CONTEXT_ID
								AND TRUST_PURPOSE_ID = l_ctp.TRUST_PURPOSE_ID;

						t_ctp2.PATH_LEN_CONSTRAINT := greatest(
							t_ctp1.PATH_LEN_CONSTRAINT,
							least(
								l_ctp.PATH_LEN_CONSTRAINT - 1,
								coalesce(x509_getPathLenConstraint(l_ctp.CERTIFICATE),
											max_iterations)
							)
						);
						t_ctp2.EARLIEST_NOT_BEFORE := least(
							t_ctp1.EARLIEST_NOT_BEFORE,
							greatest(
								l_ctp.EARLIEST_NOT_BEFORE,
								x509_notBefore(l_ctp.CERTIFICATE)
							)
						);
						t_ctp2.LATEST_NOT_AFTER := greatest(
							t_ctp1.LATEST_NOT_AFTER,
							least(
								l_ctp.LATEST_NOT_AFTER,
								x509_notAfter(l_ctp.CERTIFICATE)
							)
						);
						t_ctp2.ALL_CHAINS_TECHNICALLY_CONSTRAINED := least(
							t_ctp1.ALL_CHAINS_TECHNICALLY_CONSTRAINED,
							greatest(
								l_ctp.ALL_CHAINS_TECHNICALLY_CONSTRAINED,
								is_technically_constrained(l_ctp.CERTIFICATE)
							)
						);
						t_ctp2.ALL_CHAINS_REVOKED := least(
							t_ctp1.ALL_CHAINS_REVOKED,
							greatest(l_ctp.ALL_CHAINS_REVOKED, t_isRevoked)
						);

						IF (t_ctp1.PATH_LEN_CONSTRAINT != t_ctp2.PATH_LEN_CONSTRAINT)
								OR (t_ctp1.EARLIEST_NOT_BEFORE != t_ctp2.EARLIEST_NOT_BEFORE)
								OR (t_ctp1.LATEST_NOT_AFTER != t_ctp2.LATEST_NOT_AFTER)
								OR (t_ctp1.ALL_CHAINS_TECHNICALLY_CONSTRAINED != t_ctp2.ALL_CHAINS_TECHNICALLY_CONSTRAINED)
								OR (t_ctp1.ALL_CHAINS_REVOKED != t_ctp2.ALL_CHAINS_REVOKED) THEN
							UPDATE ca_trust_purpose_temp
								SET PATH_LEN_CONSTRAINT = t_ctp2.PATH_LEN_CONSTRAINT,
									EARLIEST_NOT_BEFORE = t_ctp2.EARLIEST_NOT_BEFORE,
									LATEST_NOT_AFTER = t_ctp2.LATEST_NOT_AFTER,
									ALL_CHAINS_TECHNICALLY_CONSTRAINED = t_ctp2.ALL_CHAINS_TECHNICALLY_CONSTRAINED,
									ALL_CHAINS_REVOKED = t_ctp2.ALL_CHAINS_REVOKED,
									LONGEST_CHAIN = t_iteration + 1
								WHERE CA_ID = coalesce(t_caID, -l_ctp.ID)
									AND TRUST_CONTEXT_ID = l_ctp.TRUST_CONTEXT_ID
									AND TRUST_PURPOSE_ID = l_ctp.TRUST_PURPOSE_ID;
							t_nothingChanged := FALSE;
						END IF;
					END IF;
			END;
		END LOOP;
		t_iteration := t_iteration + 1;
		EXIT WHEN t_nothingChanged;
	END LOOP;

	RETURN t_iteration - 1;
END;
$$ LANGUAGE plpgsql;
